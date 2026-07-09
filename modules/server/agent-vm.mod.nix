# Agent-fleet worker guests. See docs/agent-fleet.md. Each worker is a
# minimal, purpose-built NixOS microVM — deliberately NOT composed from
# self.nixosModules (workers are not fleet hosts; no tailnet, no monorepo,
# no host secrets, by absence). Claude Code runs fully-permissioned inside;
# containment is the host's default-deny egress, not anything the guest
# promises: the guest has no default route and no DNS, so the squid
# allowlist proxy on the bridge IP is structurally the only way out.
#
# Ephemerality: the guest root is tmpfs (microvm.nix default) and the nix
# store is the host's, read-only over virtiofs. The two volume images (store
# overlay + /workspace scratch) are deleted on every VM start (ExecStartPre
# below; the runner recreates them blank), so nothing an agent writes
# survives a restart — a compromised or wedged worker is one
# `systemctl restart microvm@<name>` from pristine.
#
# CREDENTIALS: agents authenticate with subscription logins (Claude Code
# OAuth token, Codex auth.json) plus one fine-grained GitHub PAT per worker
# class, scoped to that class's single repo — the PAT's scope IS the
# containment boundary on the forge side. cloud-hypervisor does not support
# microvm.credentialFiles (qemu-only), so each worker gets a read-only
# virtiofs share of a root-owned host directory holding exactly its own
# credentials, assembled from the agenix-decrypted files by a host oneshot.
# Never put secrets in the nix store — guests read the ENTIRE host store.
{
  flake.nixosModules.agent-guests =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      inherit (lib.attrsets) listToAttrs nameValuePair optionalAttrs;
      inherit (lib.lists) concatMap singleton;
      inherit (lib.meta) getExe';
      inherit (lib.modules) mkForce mkIf;
      inherit (lib.options) mkOption;
      inherit (lib.strings) concatMapStringsSep fixedWidthString optionalString;
      inherit (lib) types;

      guide = import ../../lib/fleet-guide.nix;
      hintFile = pkgs.writeText "worker-hint.md" (guide.system + guide.worker);

      cfg = config.agentFleet;

      hostAddr = "10.100.0.1";
      proxyUrl = "http://${hostAddr}:3128";

      credsDir = name: "/run/agents/creds/${name}";
      guestCredsMount = "/run/host-creds";

      # Per-worker task exchange: the dispatcher (agent-dispatch.mod.nix)
      # writes prompt.md here before booting the VM; the guest's agent-task
      # unit writes report.md/agent.log/exit-code back, and ask-cockpit
      # exchanges question-N.md/answer-N.md through it mid-task. The guest
      # `agent` user is uid 1000/gid 100, which passes through virtiofs
      # verbatim, so the host-side directory is owned by uid 1000.
      workDir = name: "/var/lib/agents/work/${name}/task";
      guestTaskMount = "/run/task";

      # Per-worker volume images, wiped on every VM start (see ExecStartPre).
      volumes = [
        {
          image = "nix-overlay.img"; # writable nix-store overlay
          mountPoint = "/nix/.rw-store";
          size = 8192;
        }
        {
          image = "workspace.img"; # the agent's scratch checkout/build dir
          mountPoint = "/workspace";
          size = 20480;
        }
      ];

      # One worker class per repo; `index` numbers workers within the fleet
      # and derives both the bridge address (10.100.0.10+index) and a
      # locally-administered MAC. The decimal index doubles as the MAC's
      # last octet — unique for index <= 99, which is plenty.
      mkAgentGuest =
        {
          name,
          index,
          repo,
          patFile,
          vcpu,
          mem,
          ...
        }:
        let
          addr = "10.100.0.${toString (10 + index)}";
          mac = "02:00:00:00:00:${fixedWidthString 2 "0" (toString index)}";
        in
        {
          # Manual lifecycle: the cockpit starts/stops microvm@<name> by
          # hand; nothing autostarts at boot.
          autostart = false;

          config =
            { pkgs, ... }:
            let
              # Mid-task escalation: writes a question into the task share and
              # blocks until the host's guidance service (agent-dispatch.mod.nix)
              # answers it with a stronger model. Capped per task so a confused
              # agent can't burn the cockpit's quota in a loop.
              askCockpit = pkgs.writeShellApplication {
                name = "ask-cockpit";
                text = ''
                  if [ $# -lt 1 ]; then
                    echo "usage: ask-cockpit <question...>" >&2
                    exit 2
                  fi
                  task=${guestTaskMount}
                  n=1
                  while [ -e "$task/question-$n.md" ] || [ -e "$task/answer-$n.md" ]; do
                    n=$((n + 1))
                    if [ "$n" -gt 5 ]; then
                      echo "guidance limit (5 questions) reached for this task; proceed on your best judgment" >&2
                      exit 1
                    fi
                  done
                  printf '%s\n' "$*" > "$task/question-$n.md.tmp"
                  mv "$task/question-$n.md.tmp" "$task/question-$n.md"
                  for _ in $(seq 1 180); do
                    if [ -e "$task/answer-$n.md" ]; then
                      cat "$task/answer-$n.md"
                      exit 0
                    fi
                    sleep 5
                  done
                  echo "no guidance arrived within 15 minutes; proceed on your best judgment"
                '';
              };
            in
            {
              microvm = {
                hypervisor = "cloud-hypervisor";
                inherit vcpu mem;

                # Unique per-VM vsock context ID (any u32 >= 3); lets the
                # guest's systemd send readiness notifications to the runner.
                # The host side is a unix socket in the VM's state dir, not a
                # network path out.
                vsock.cid = 100 + index;

                interfaces = singleton {
                  type = "tap";
                  id = "vm-${name}"; # enslaved to br-agents by the networkd vm-* match
                  inherit mac;
                };

                shares = [
                  # The host's store, read-only. Note this exposes the ENTIRE
                  # host store to the guest — never put secrets in the store.
                  {
                    proto = "virtiofs";
                    tag = "ro-store";
                    source = "/nix/store";
                    mountPoint = "/nix/.ro-store";
                  }
                  # This worker's credentials, assembled on the host by
                  # agent-creds-<name>.service (below) and installed in-guest
                  # by agent-credentials.service.
                  {
                    proto = "virtiofs";
                    tag = "creds";
                    source = credsDir name;
                    mountPoint = guestCredsMount;
                    readOnly = true;
                  }
                  # Task in, report out (see agent-task below).
                  {
                    proto = "virtiofs";
                    tag = "task";
                    source = workDir name;
                    mountPoint = guestTaskMount;
                    # Warm pool delivers prompt.md into a RUNNING guest. With
                    # default caching the guest keeps a stale negative dentry for
                    # a never-existed file it stats without ever touching the dir,
                    # so it never sees the host's write. cache=never makes the
                    # guest always revalidate against the host. (Tiny control-
                    # plane share, so no meaningful perf cost.)
                    cache = "never";
                  }
                ];

                # Writable overlay so `nix build` works inside the guest.
                writableStoreOverlay = "/nix/.rw-store";
                inherit volumes;
              };

              # NETWORKING — static address on the host-only bridge subnet,
              # deliberately NO gateway and NO DNS: the guest cannot route or
              # resolve anything. Squid does all resolving on its behalf.
              networking.useNetworkd = true;
              networking.useDHCP = false;
              systemd.network.networks."20-lan" = {
                matchConfig.MACAddress = mac;
                address = singleton "${addr}/24";
              };

              # Everything HTTP(S) goes through the proxy. networking.proxy
              # covers the lowercase env vars plus nix-daemon; Claude Code and
              # Codex (Node) want the uppercase forms, set explicitly.
              networking.proxy.default = proxyUrl;
              environment.variables = {
                HTTP_PROXY = proxyUrl;
                HTTPS_PROXY = proxyUrl;
                NO_PROXY = "127.0.0.1,localhost";
              }
              # The one repo this worker class works on, when it is bound to
              # one at all.
              // optionalAttrs (repo != null) { AGENT_REPO = "https://github.com/${repo}.git"; };

              environment.systemPackages = [
                askCockpit
                pkgs.claude-code
                pkgs.codex
                pkgs.git
                pkgs.gh
                pkgs.ripgrep
                pkgs.fd
                pkgs.jq
                pkgs.curl
                pkgs.gnumake
                pkgs.gcc
              ];

              nix.settings.experimental-features = [
                "flakes"
                "nix-command"
              ];
              # Substituters stay at the default cache.nixos.org — the only
              # cache on the egress allowlist (.nixos.org).

              # CREDENTIAL INSTALL — copies the host share into place for the
              # agent user: an env file with the Claude OAuth token and the
              # repo PAT (sourced by login shells; non-login invocations must
              # `. /run/agent-env` themselves), and Codex's auth.json.
              systemd.services.agent-credentials = {
                description = "Install worker credentials from the host share";
                wantedBy = [ "multi-user.target" ];
                before = [ "multi-user.target" ];
                unitConfig.RequiresMountsFor = [ guestCredsMount ];
                serviceConfig = {
                  Type = "oneshot";
                  RemainAfterExit = true;
                };
                script = ''
                  umask 077
                  {
                    printf 'export CLAUDE_CODE_OAUTH_TOKEN=%q\n' "$(cat ${guestCredsMount}/claude-token)"
                    ${optionalString (patFile != null) ''
                      printf 'export GH_TOKEN=%q\n' "$(cat ${guestCredsMount}/repo-pat)"
                    ''}
                  } > /run/agent-env
                  chown agent:users /run/agent-env
                  chmod 0400 /run/agent-env
                  install -d -m 0700 -o agent -g users /home/agent/.codex
                  install -m 0400 -o agent -g users ${guestCredsMount}/codex-auth.json /home/agent/.codex/auth.json
                '';
              };
              environment.extraInit = ''[ -r /run/agent-env ] && . /run/agent-env'';

              # TASK RUNNER — if the dispatcher staged a prompt in the task
              # share before boot, run it headless as the agent user and
              # write the results back. One task per VM lifetime: the volumes
              # are wiped on start, so boot state is always pristine and this
              # unit's ConditionPathExists decides whether this is a task run
              # or an idle/debugging boot.
              # Type=exec, NOT oneshot: the guest's pid1 reports readiness to
              # the VMM (the VM unit is Type=notify via vsock) only once the
              # boot transaction settles, and a oneshot's start job lasts for
              # the whole task — a long task would hold the host-side
              # `systemctl start microvm@<name>` until its 150s timeout. An
              # exec start job completes at fork, so boot settles in seconds
              # while the task runs on.
              systemd.services.agent-task = {
                description = "Run the dispatched task";
                wantedBy = [ "multi-user.target" ];
                requires = [ "agent-credentials.service" ];
                after = [ "agent-credentials.service" ];
                unitConfig = {
                  # No ConditionPathExists on prompt.md: the guest boots idle and
                  # the wait loop in the script blocks until the host delivers a
                  # task, so gating the unit on the file existing would skip it
                  # entirely on a warm (empty-share) boot.
                  RequiresMountsFor = [ guestTaskMount ];
                };
                # The full system path, not a minimal tool list: the agent's
                # shell inherits this unit's PATH, and it needs everything
                # installed in the guest (git, gh, ask-cockpit, compilers...).
                path = [ "/run/current-system/sw" ];
                serviceConfig = {
                  Type = "exec";
                  User = "agent";
                  Group = "users";
                  WorkingDirectory = "/workspace";
                  # Units don't read /etc/set-environment; restate the proxy.
                  # The Bash timeouts let a blocking ask-cockpit call outlive
                  # Claude Code's 2-minute default tool timeout (guidance
                  # takes minutes; killing the wait made agents re-ask).
                  Environment = [
                    "HTTP_PROXY=${proxyUrl}"
                    "HTTPS_PROXY=${proxyUrl}"
                    "NO_PROXY=127.0.0.1,localhost"
                    "BASH_DEFAULT_TIMEOUT_MS=1200000"
                    "BASH_MAX_TIMEOUT_MS=1800000"
                  ];
                };
                # The prompt may start with a front-matter block setting task
                # options; unknown keys are ignored. Currently understood:
                #   ---
                #   agent: claude        <- required executor: claude | codex
                #   model: sonnet        <- required executor --model value
                #   ---
                # New executors are one more case branch below; the contract
                # is only: read prompt body, write report.md + agent.log +
                # exit-code, run with everything auto-approved (the VM is the
                # sandbox — that's the point of the fleet).
                script = ''
                  . /run/agent-env
                  prompt=${guestTaskMount}/prompt.md

                  # Warm pool: boot idle and wait for the host to deliver a task.
                  # DIAGNOSTIC (temporary): prove this watcher is alive and log what
                  # the guest's OWN view of the task dir sees while waiting. Written
                  # to the share; guest->host writes ARE visible to the host, so we
                  # can read diag.log on the host side. The periodic `ls` also tests
                  # whether a readdir reveals the host-delivered prompt when a plain
                  # stat (`[ -f ]`) does not. Remove once delivery is settled.
                  {
                    echo "agent-task started: $(date)"
                    echo "initial ls of ${guestTaskMount}:"
                    ls -la ${guestTaskMount}
                  } > ${guestTaskMount}/diag.log 2>&1
                  i=0
                  while [ ! -f "$prompt" ]; do
                    i=$((i + 1))
                    if [ $((i % 5)) -eq 0 ]; then
                      {
                        echo "--- poll $i ($(date)): guest ls of ${guestTaskMount}:"
                        ls -la ${guestTaskMount}
                      } >> ${guestTaskMount}/diag.log 2>&1
                    fi
                    sleep 1
                  done
                  echo "SAW PROMPT at poll $i: $(date)" >> ${guestTaskMount}/diag.log 2>&1

                  fm() {
                    awk -v key="$1" '
                      NR==1 && $0=="---" { h=1; next }
                      h && $0=="---" { exit }
                      h && substr($0, 1, length(key)+1) == key ":" {
                        sub(/^[[:alnum:]_-]+:[[:space:]]*/, ""); print; exit
                      }
                    ' "$prompt"
                  }
                  agent="$(fm agent)"
                  model="$(fm model)"
                  awk '
                    NR==1 && $0=="---" { h=1; next }
                    h && $0=="---" { h=0; next }
                    h { next }
                    { print }
                  ' "$prompt" > /tmp/prompt-body.md

                  hint="$(cat ${hintFile})"

                  rc=0
                  if [ -z "$agent" ] || [ -z "$model" ]; then
                    echo "task rejected: agent and model must both be specified" | tee ${guestTaskMount}/report.md > ${guestTaskMount}/agent.log
                    rc=64
                  else
                    case "$agent" in
                      claude)
                        claude -p "$(cat /tmp/prompt-body.md)" --model "$model" \
                          --dangerously-skip-permissions \
                          --append-system-prompt "$hint" \
                          > ${guestTaskMount}/report.md \
                          2> ${guestTaskMount}/agent.log || rc=$?
                        ;;
                      codex)
                        # No system-prompt flag; the hint rides atop the prompt.
                        # stdout is the session transcript (-> agent.log); the
                        # final message is the report.
                        codex exec \
                          --dangerously-bypass-approvals-and-sandbox \
                          --skip-git-repo-check \
                          --model "$model" \
                          --output-last-message ${guestTaskMount}/report.md \
                          "$hint

                        $(cat /tmp/prompt-body.md)" \
                          > ${guestTaskMount}/agent.log 2>&1 < /dev/null || rc=$?
                        ;;
                      *)
                        echo "unknown agent '$agent' (known: claude, codex)" | tee ${guestTaskMount}/report.md > ${guestTaskMount}/agent.log
                        rc=64
                        ;;
                    esac
                  fi
                  echo "$rc" > ${guestTaskMount}/exit-code
                '';
              };

              # git pushes over HTTPS with the PAT; gh turns $GH_TOKEN into
              # git credentials, so no token is ever written into gitconfig.
              programs.git = {
                enable = true;
                config = {
                  credential."https://github.com".helper = "!gh auth git-credential";
                  user.name = name;
                  user.email = "${name}@agents.invalid";
                };
              };

              # The sole account. No wheel, no sudo; it owns /workspace and
              # nothing else. No SSH into guests at all — tasks and results
              # move over the task share, and the only interactive way in is
              # the serial console below.
              users.users.agent = {
                isNormalUser = true;
                description = "fleet worker";
              };
              systemd.tmpfiles.rules = singleton "d /workspace 0755 agent users -";

              # Root autologin on the serial console: reaching the console at
              # all requires host-root (the microvm@ unit's PTY), and guest
              # containment never rests on in-guest auth. Keeps verification
              # and debugging one `microvm -s <name>` away.
              services.getty.autologinUser = "root";

              system.stateVersion = "26.05";
            };
        };
    in
    {
      # The fleet roster. Everything derived from a worker (the VM definition,
      # its credentials, AND its slice fence) is generated from this one list,
      # so a worker can never exist outside the agents.slice memory budget or
      # with credentials broader than its own class's.
      options.agentFleet = {
        workers = mkOption {
          description = "agent-fleet worker roster; repo-specificity lives only here and in the injected PAT";
          default = [ ];
          type = types.listOf (
            types.submodule {
              options = {
                name = mkOption { type = types.str; };
                index = mkOption { type = types.ints.between 1 99; };
                repo = mkOption {
                  type = types.nullOr types.str;
                  default = null;
                  example = "cdland/lfish";
                  description = "GitHub owner/repo this worker class is bound to; null = a generic worker with no repo binding";
                };
                patFile = mkOption {
                  type = types.nullOr types.str;
                  default = null;
                  description = "host path of the fine-grained PAT scoped to exactly this repo; null = no push credential (worker can still run agents and clone public repos)";
                };
                vcpu = mkOption {
                  type = types.int;
                  default = 8;
                };
                mem = mkOption {
                  type = types.int;
                  default = 8192; # MiB, static — no ballooning
                };
              };
            }
          );
        };

        # Subscription credentials shared by every worker (one Claude Max +
        # one ChatGPT login for the whole fleet).
        credentials = {
          claudeTokenFile = mkOption {
            type = types.str;
            description = "host path of the Claude Code OAuth token (from `claude setup-token`)";
          };
          codexAuthFile = mkOption {
            type = types.str;
            description = "host path of a copy of Codex's auth.json (from a ChatGPT login)";
          };
        };
      };

      config = mkIf cfg.enable {
        microvm.vms = listToAttrs (map (w: nameValuePair w.name (mkAgentGuest w)) cfg.workers);

        # Task-share sources must exist before virtiofsd starts, VM-managed
        # or not. Writable by the guest agent (uid 1000, see workDir above).
        systemd.tmpfiles.rules = map (w: "d ${workDir w.name} 0755 1000 100 -") cfg.workers;

        systemd.services = listToAttrs (
          concatMap (w: [
            # microvm.nix has no slice option; standard unit override so every
            # worker counts against the fleet's 48G/agents.slice fence.
            (nameValuePair "microvm@${w.name}" {
              serviceConfig = {
                Slice = "agents.slice";
                # The drainer owns worker lifecycle; upstream's Restart=always
                # (VMs as long-running services) would fight its stop/start.
                Restart = mkForce "no";
                # Don't wait on a graceful guest poweroff — the guest is
                # ephemeral (volumes are wiped on next start), so a clean
                # shutdown buys nothing and the guest's own poweroff is slow.
                # Bound the stop so systemd SIGKILLs the VMM almost at once,
                # reclaiming ~45s/task. (Default was 90s; the guest was taking
                # the better part of a minute to power off cleanly.)
                TimeoutStopSec = mkForce 3;
                # EPHEMERALITY — delete the volume images before every start;
                # the runner's autoCreate recreates them blank (truncate +
                # mkfs), so each boot is a clean slate.
                ExecStartPre = singleton (
                  "${getExe' pkgs.coreutils "rm"} -f "
                  + concatMapStringsSep " " (v: "${config.microvm.stateDir}/${w.name}/${v.image}") volumes
                );
              };
            })

            # Assemble this worker's credential directory (0700 root) from
            # the agenix-decrypted host secrets. virtiofsd runs as root, so
            # the guest can be served files the microvm user cannot read.
            (nameValuePair "agent-creds-${w.name}" {
              description = "Assemble credentials for agent worker ${w.name}";
              requiredBy = [ "microvm-virtiofsd@${w.name}.service" ];
              before = [ "microvm-virtiofsd@${w.name}.service" ];
              serviceConfig = {
                Type = "oneshot";
                RemainAfterExit = true;
              };
              script = ''
                # -o/-g matter: microvm.nix pre-creates share sources owned
                # by the microvm user; this directory must stay root-only.
                install -d -m 0700 -o root -g root ${credsDir w.name}
                install -m 0400 ${cfg.credentials.claudeTokenFile} ${credsDir w.name}/claude-token
                install -m 0400 ${cfg.credentials.codexAuthFile} ${credsDir w.name}/codex-auth.json
                ${optionalString (w.patFile != null) ''
                  install -m 0400 ${w.patFile} ${credsDir w.name}/repo-pat
                ''}
              '';
            })
          ]) cfg.workers
        );
      };
    };
}
