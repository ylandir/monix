# Agent-fleet dispatcher. See docs/agent-fleet.md. Turns the fleet into a
# drop-a-file service: a task is a markdown prompt placed in the queue
# directory; a worker runs it on a pristine VM and the report comes back —
# no SSH into guests, no forge in the loop.
#
#   /var/lib/agents/tasks/queue/<name>.md   <- tasks land here, enqueued by the
#                                              `fleet` tool run as the operator
#                                              user (see fleet-tool.mod.nix); the
#                                              queue is operator-owned, not
#                                              wheel-writable
#   /var/lib/agents/tasks/done/<id>/        <- prompt.md + report.md + agent.log
#   /var/lib/agents/tasks/failed/<id>/      <- same, for nonzero exit or timeout
#   /var/lib/agents/tasks/rejected/         <- quarantined non-regular queue entries
#
# Scheduling: one resident drainer per roster worker maintains a fresh warm VM,
# atomically claims queued tasks, and delivers each prompt into an already-live
# guest. After one task it stops the VM, safely archives bounded output, wipes
# the writable volumes, and boots a fresh idle replacement.
{
  flake.nixosModules.agent-dispatch =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      inherit (lib.attrsets) listToAttrs nameValuePair;
      inherit (lib.meta) getExe;
      inherit (lib.modules) mkIf;
      inherit (lib.options) mkOption;
      inherit (lib.strings) hasSuffix;
      inherit (lib) types;

      cfg = config.agentFleet;
      op = cfg.operatorUser;
      topology = import ../../lib/fleet-topology.nix;
      inherit (topology) tasksDir;
      readers = topology.readersGroup;
      agentDispatcher = pkgs.rustPlatform.buildRustPackage {
        pname = "agent-dispatcher";
        version = "0.1.0";
        src = lib.sources.cleanSourceWith {
          src = ./agent-dispatch;
          filter = path: type: type != "directory" || !hasSuffix "/target" (toString path);
        };

        cargoLock.lockFile = ./agent-dispatch/Cargo.lock;
        meta.mainProgram = "agent-dispatcher";
      };

      drainerFor =
        worker:
        let
          work = "/var/lib/agents/work/${worker}/task";
          creds = "/run/agents/creds/${worker}";
        in
        {
          description = "Drain the agent task queue on worker ${worker}";
          wantedBy = [ "multi-user.target" ];
          after = [ "agent-results-permissions.service" ];
          startLimitIntervalSec = 0;
          path = [
            pkgs.coreutils
            pkgs.jq
            pkgs.systemd
          ];
          serviceConfig = {
            Slice = "agents.slice";
            ExecStart = getExe agentDispatcher;
            Restart = "always";
            RestartSec = 2;
          };
          environment = {
            FLEET_TASKS_DIR = tasksDir;
            FLEET_WORKER = worker;
            FLEET_WORK_DIR = work;
            FLEET_CREDS_DIR = creds;
            FLEET_CLAUDE_TOKEN_FILE = cfg.credentials.claudeTokenFile;
            FLEET_CODEX_AUTH_FILE = cfg.credentials.codexAuthFile;
            FLEET_OPENROUTER_KEY_FILE =
              if cfg.credentials.openrouterKeyFile == null then
                ""
              else
                toString cfg.credentials.openrouterKeyFile;
            FLEET_READERS = readers;
            FLEET_STALL_TIMEOUT = toString cfg.stallTimeout;
            FLEET_WARM_MAX_AGE = toString cfg.warmMaxAge;
            FLEET_TASK_TIMEOUT = toString cfg.taskTimeout;
            FLEET_TASK_EXCHANGE_MAX_BYTES = toString cfg.taskExchangeMaxBytes;
            FLEET_TASK_CONTEXT_MAX_BYTES = toString cfg.taskContextMaxBytes;
          };
        };
    in
    {
      options.agentFleet.stallTimeout = mkOption {
        type = types.int;
        default = 120;
        description = "seconds with no guest heartbeat before a task is treated as stalled/dead and killed";
      };

      options.agentFleet.warmMaxAge = mkOption {
        type = types.int;
        default = 7200;
        description = "seconds an idle warm VM may live before it is preventively destroyed and rebooted";
      };

      options.agentFleet.taskTimeout = mkOption {
        type = types.int;
        default = 21600;
        description = "absolute max seconds a task may run before the worker is stopped and the task filed as failed, regardless of progress";
      };

      options.agentFleet.taskExchangeMaxBytes = mkOption {
        type = types.int;
        default = 805306368;
        description = "maximum total bytes in one live worker task exchange before the task is stopped";
      };

      options.agentFleet.taskContextMaxBytes = mkOption {
        type = types.int;
        default = 536870912;
        description = "maximum compressed context capsule bytes accepted for one task";
      };

      config = mkIf (cfg.enable && cfg.workers != [ ]) {
        systemd.tmpfiles.rules = [
          "d ${tasksDir} 0755 root root -"
          "d ${tasksDir}/queue 0770 root ${op} -"
          "d ${tasksDir}/running 0755 root root -"
          "d ${tasksDir}/done 0750 root ${readers} -"
          "d ${tasksDir}/failed 0750 root ${readers} -"
          "d ${tasksDir}/rejected 0750 root ${readers} -"
          "d ${tasksDir}/live 0750 root ${readers} -"
          "d ${tasksDir}/steer 0770 root ${op} -"
          "d ${tasksDir}/answers 0770 root ${op} -"
          "d ${tasksDir}/cancel 0770 root ${op} -"
          "f ${tasksDir}/log 0664 root ${op} -"
        ];

        systemd.services = {
          agent-results-permissions = {
            description = "Restrict agent result archives to fleet readers";
            wantedBy = [ "multi-user.target" ];
            before = map (w: "agent-dispatch-${w.name}.service") cfg.workers;
            path = [
              pkgs.coreutils
              pkgs.findutils
            ];
            unitConfig.ConditionPathExists = "!${tasksDir}/.permissions-v1";
            serviceConfig.Type = "oneshot";
            script = ''
              for dir in ${tasksDir}/done ${tasksDir}/failed ${tasksDir}/rejected; do
                [ -d "$dir" ] || continue
                chown root:${readers} "$dir"
                chmod 0750 "$dir"
                find "$dir" -mindepth 1 -type d -exec chown root:${readers} {} + -exec chmod 0750 {} +
                find "$dir" -type f -exec chown root:${readers} {} + -exec chmod 0640 {} +
              done
              touch ${tasksDir}/.permissions-v1
            '';
          };
        }
        // listToAttrs (map (w: nameValuePair "agent-dispatch-${w.name}" (drainerFor w.name)) cfg.workers);
      };
    };
}
