# Agent-fleet worker guests. See docs/agent-fleet.md. Each worker is a
# minimal, purpose-built NixOS microVM — deliberately NOT composed from
# self.nixosModules (workers are not fleet hosts; no tailnet, no monorepo,
# no host secrets, by absence). Claude Code runs fully-permissioned inside;
# containment is the host's default-deny egress, not anything the guest
# promises: the guest has no default route and no DNS, so the squid
# allowlist proxy on the bridge IP is structurally the only way out.
#
# Ephemerality: the guest root is tmpfs (microvm.nix default) and the nix
# store is a read-only erofs image of the guest closure (microvm.nix
# storeOnDisk), opened once at boot. Sharing the host's live store over
# virtiofs was the warm-VM-rot root cause (diagnosed 2026-07-14): host
# `nix-optimise` renames hard links over store files, replacing inodes
# under virtiofsd, and running guests wedge permanently the first time
# their own closure gets optimised; host gc could likewise delete paths
# under old-closure guests (they held no gc root). A block-device store
# decouples guests from all host store churn — and because every worker
# boots the SAME closure (per-VM identity arrives on the kernel command
# line, never in the config), nix builds exactly ONE image for the fleet.
# The two volume images (store overlay + /workspace scratch) are deleted
# on every VM start (ExecStartPre below; the runner recreates them blank),
# so nothing an agent writes survives a restart — a compromised or wedged
# worker is one `systemctl restart microvm@<name>` from pristine.
#
# CREDENTIALS: idle guests have an empty read-only credential share. After a
# task is claimed, the host drainer stages exactly the selected executor's
# credential and publishes prompt.md last. The guest validates and installs
# that one credential into the executor's private home; local tasks receive
# none. The VM is stopped before the host clears the share. Never put secrets
# in the nix store — the guest image is built from it, and the cockpit's
# own store is world-readable on the host anyway.
{
  flake.nixosModules.agent-guests =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      inherit (lib.attrsets)
        listToAttrs
        mapAttrsToList
        nameValuePair
        optionalAttrs
        ;
      inherit (lib.lists) concatLists concatMap singleton;
      inherit (lib.meta) getExe getExe';
      inherit (lib.modules) mkForce mkIf;
      inherit (lib.options) mkOption;
      inherit (lib.strings) concatMapStringsSep fixedWidthString hasSuffix optionalString;
      inherit (lib) types;

      guide = import ../../lib/fleet-guide.nix;
      hintFile = pkgs.writeText "worker-hint.md" (guide.system + guide.worker);

      cfg = config.agentFleet;

      topology = import ../../lib/fleet-topology.nix;
      inherit (topology) hostAddr;
      proxyUrl = "http://${hostAddr}:3128";
      # Direct (non-proxied) guest destinations: local inference bypasses
      # squid — it's plain HTTP to a bridge IP, which the CONNECT allowlist
      # could never express; the br-agents pinhole is its firewall instead.
      noProxy = "127.0.0.1,localhost,${hostAddr}";

      # Guest opencode configuration. When the host serves local inference
      # (inference.mod.nix), expose it to opencode as a `local` provider —
      # the model catalog (and its aliases) is generated from the SAME
      # inference.models the host serves, so guest model ids can never
      # drift from what llama-swap actually offers. Dispatch as
      # `agent: opencode` + `model: local/<name>`. The ai-sdk loader wants
      # a non-empty apiKey; llama-swap ignores it.
      opencodeConfig = pkgs.writeText "opencode.json" (
        builtins.toJSON (
          {
            "$schema" = "https://opencode.ai/config.json";
          }
          // optionalAttrs config.inference.enable {
            provider.local = {
              npm = "@ai-sdk/openai-compatible";
              name = "ship-local inference (llama-swap)";
              options = {
                baseURL = "http://${hostAddr}:${toString config.inference.port}/v1";
                apiKey = "local";
              };
              models = listToAttrs (
                concatLists (
                  mapAttrsToList (n: m: map (id: nameValuePair id { }) ([ n ] ++ m.aliases)) config.inference.models
                )
              );
            };
          }
        )
      );

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
          vcpu,
          mem,
          ...
        }:
        let
          addr = "10.100.0.${toString (10 + index)}";
          mac = "02:00:00:00:00:${fixedWidthString 2 "0" (toString index)}";
        in
        {
          # The generated microvm unit does not autostart itself; its resident
          # drainer owns lifecycle and maintains it as part of the warm pool.
          autostart = false;

          config =
            { pkgs, ... }:
            let
              # Mid-task escalation: writes a question into the task share and
              # blocks until an answer arrives. Only `guidance: cockpit` tasks
              # get a real answerer (the live cockpit via `fleet answer`); any
              # other task receives the drainer's immediate stock answer —
              # there is no advisor tier. Capped per task so a confused agent
              # can't loop on questions.
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
                  # 30 min: a `guidance: cockpit` task is answered by the live
                  # cockpit (possibly a human), which is slower than a model
                  # advisor. The loop exits the moment an answer lands.
                  for _ in $(seq 1 360); do
                    if [ -e "$task/answer-$n.md" ]; then
                      cat "$task/answer-$n.md"
                      exit 0
                    fi
                    sleep 5
                  done
                  echo "no guidance arrived within 30 minutes; proceed on your best judgment"
                '';
              };

              claudeExecutor = pkgs.writeShellApplication {
                name = "agent-claude-exec";
                text = ''
                  # shellcheck disable=SC1091
                  . /run/agent-claude/env
                  exec ${getExe pkgs.claude-code} "$@"
                '';
              };

              codexExecutor = pkgs.writeShellApplication {
                name = "agent-codex-exec";
                text = ''
                  exec ${getExe pkgs.codex} "$@"
                '';
              };

              opencodeExecutor = pkgs.writeShellApplication {
                name = "agent-opencode-exec";
                text = ''
                  # shellcheck disable=SC1091
                  [ ! -r /run/agent-opencode/env ] || . /run/agent-opencode/env
                  exec ${getExe pkgs.opencode} "$@"
                '';
              };

              localExecutor = pkgs.writeShellApplication {
                name = "agent-local-exec";
                text = ''
                  exec ${getExe pkgs.opencode} "$@"
                '';
              };

              # The guest task supervisor (modules/server/agent-vm/): the
              # Rust replacement for the previous embedded Bash script. All
              # orchestration, validation, lifecycle, and publication logic
              # lives in the crate; its tests (metadata/credential matrices,
              # loop compatibility, usage normalization fixtures, publication
              # ordering) run in the package's checkPhase.
              guestSupervisor = pkgs.rustPlatform.buildRustPackage {
                pname = "fleet-guest-supervisor";
                version = "0.1.0";
                src = lib.sources.cleanSourceWith {
                  src = ./agent-vm;
                  filter = path: type: type != "directory" || !hasSuffix "/target" (toString path);
                };

                cargoLock.lockFile = ./agent-vm/Cargo.lock;
                # The usage-normalization fixture tests drive the same fixed
                # external tools the supervisor invokes at runtime.
                nativeCheckInputs = [
                  pkgs.jq
                  pkgs.sqlite
                ];
                meta.mainProgram = "fleet-guest-supervisor";
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

                # The guest store is an erofs image of the guest closure, NOT
                # a share of the host's live store: host store maintenance
                # (optimise/gc) mutating inodes under virtiofsd was the
                # warm-VM-rot root cause (see header). The image is opened as
                # a block device at boot, so even deleting it on the host
                # cannot touch a running guest.
                storeOnDisk = true;

                # Per-VM identity travels on the kernel command line (host-
                # side runner argument — NOT part of the guest closure, which
                # must stay identical across workers so the fleet shares one
                # store disk). Adopted at boot by drone-identity below.
                kernelParams = [
                  "drone.name=${name}"
                  "drone.addr=${addr}/24"
                ];

                shares = [
                  # Empty while idle; the host drainer atomically stages only
                  # the credential selected by the claimed task before it
                  # publishes prompt.md.
                  {
                    proto = "virtiofs";
                    tag = "creds";
                    source = credsDir name;
                    mountPoint = guestCredsMount;
                    readOnly = true;
                    cache = "never";
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
              # The address (and hostname) come from the kernel command line
              # so the closure stays identical across workers; drone-identity
              # writes the networkd unit into /run before networkd starts.
              # (A guest could always self-assign any address — per-VM
              # enforcement never lived here; it lives host-side on the tap.)
              networking.useNetworkd = true;
              networking.useDHCP = false;
              networking.hostName = "drone"; # overridden at boot from cmdline
              systemd.services.drone-identity = {
                description = "Adopt per-VM identity from the kernel command line";
                wantedBy = [ "sysinit.target" ];
                before = [ "systemd-networkd.service" ];
                requiredBy = [ "systemd-networkd.service" ];
                unitConfig.DefaultDependencies = false;
                serviceConfig.Type = "oneshot";
                serviceConfig.RemainAfterExit = true;
                script = ''
                  name= addr=
                  read -r cmdline < /proc/cmdline
                  for word in $cmdline; do
                    case "$word" in
                      drone.name=*) name=''${word#drone.name=} ;;
                      drone.addr=*) addr=''${word#drone.addr=} ;;
                    esac
                  done
                  if [ -n "$name" ]; then
                    printf '%s' "$name" > /proc/sys/kernel/hostname
                  fi
                  if [ -n "$addr" ]; then
                    mkdir -p /run/systemd/network
                    printf '[Match]\nType=ether\n\n[Network]\nAddress=%s\n' \
                      "$addr" > /run/systemd/network/20-lan.network
                  fi
                '';
              };

              # Everything HTTP(S) goes through the proxy. networking.proxy
              # covers the lowercase env vars plus nix-daemon; Claude Code and
              # Codex (Node) want the uppercase forms, set explicitly.
              networking.proxy.default = proxyUrl;
              networking.proxy.noProxy = noProxy;
              environment.variables = {
                HTTP_PROXY = proxyUrl;
                HTTPS_PROXY = proxyUrl;
                NO_PROXY = noProxy;
                # opencode reads its provider catalog (incl. the host's local
                # inference endpoint) from this read-only store path.
                OPENCODE_CONFIG = "${opencodeConfig}";
              };

              environment.systemPackages = [
                askCockpit
                claudeExecutor
                codexExecutor
                opencodeExecutor
                localExecutor
                pkgs.git
                pkgs.ripgrep
                pkgs.fd
                pkgs.jq
                # usage.json extraction reads opencode's SQLite store
                pkgs.sqlite
                pkgs.curl
                pkgs.gnumake
                pkgs.gcc
                pkgs.gnutar
                pkgs.procps
                pkgs.util-linux
                pkgs.zstd
              ];

              nix.settings.experimental-features = [
                "flakes"
                "nix-command"
              ];
              # Substituters stay at the default cache.nixos.org — the only
              # cache on the egress allowlist (.nixos.org).

              # TASK RUNNER — the fleet-guest-supervisor executable (Rust,
              # modules/server/agent-vm/) waits for a delivered prompt, runs
              # it headless as the selected agent user, and writes the
              # results back. One task per VM lifetime: the volumes
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
                unitConfig = {
                  # No ConditionPathExists on prompt.md: the guest boots idle
                  # and the supervisor's wait loop blocks until the host
                  # delivers a task, so gating the unit on the file existing
                  # would skip it entirely on a warm (empty-share) boot.
                  RequiresMountsFor = [
                    guestTaskMount
                    guestCredsMount
                  ];
                };
                # The full system path, not a minimal tool list: the agent's
                # shell inherits this unit's PATH, and it needs everything
                # installed in the guest (git, ask-cockpit, compilers...);
                # the supervisor also resolves its fixed helper tools
                # (runuser, tar, git, jq, sqlite3, cp, chown, pkill) from it.
                path = [ "/run/current-system/sw" ];
                serviceConfig = {
                  Type = "exec";
                  User = "root";
                  Group = "root";
                  WorkingDirectory = "/workspace";
                  # The prompt may start with a front-matter block setting task
                  # options, but the guest never reparses executor fields from
                  # it: the host stages canonical task-meta (agent, model,
                  # effort, kind) in the read-only credential share. The
                  # supervisor's contract is: validate metadata + exactly the
                  # selected credential, prepare context as the selected
                  # unprivileged user, run the executor with everything
                  # auto-approved (the VM is the sandbox — that's the point of
                  # the fleet), then publish report.md + agent.log +
                  # changes.patch + .trusted/usage.json and exit-code LAST.
                  ExecStart = getExe guestSupervisor;
                  # Units don't read /etc/set-environment; restate the proxy.
                  # The Bash timeouts let a blocking ask-cockpit call outlive
                  # Claude Code's 2-minute default tool timeout (guidance
                  # takes minutes; killing the wait made agents re-ask).
                  Environment = [
                    "HTTP_PROXY=${proxyUrl}"
                    "HTTPS_PROXY=${proxyUrl}"
                    "NO_PROXY=${noProxy}"
                    "OPENCODE_CONFIG=${opencodeConfig}"
                    "BASH_DEFAULT_TIMEOUT_MS=1200000"
                    "BASH_MAX_TIMEOUT_MS=1800000"
                    "FLEET_GUEST_TASK_DIR=${guestTaskMount}"
                    "FLEET_GUEST_CREDS_DIR=${guestCredsMount}"
                    "FLEET_GUEST_HINT_FILE=${hintFile}"
                    "FLEET_GUEST_EXEC_CLAUDE=${getExe claudeExecutor}"
                    "FLEET_GUEST_EXEC_CODEX=${getExe codexExecutor}"
                    "FLEET_GUEST_EXEC_OPENCODE=${getExe opencodeExecutor}"
                    "FLEET_GUEST_EXEC_LOCAL=${getExe localExecutor}"
                  ];
                  # Defense in depth alongside the host's aggregate exchange
                  # budget: no single guest-created file may grow unbounded.
                  LimitFSIZE = cfg.taskExchangeMaxBytes;
                };
              };

              # Local git is used to capture a patch against the cockpit-built
              # baseline. Workers have no forge credentials or GitHub route.
              # Constant author identity: per-VM values here would fork the
              # guest closure and break the shared store disk.
              programs.git = {
                enable = true;
                config = {
                  user.name = "drone";
                  user.email = "drone@agents.invalid";
                };
              };

              # Executor identities share the disposable workspace but have
              # private 0700 homes and no wheel/sudo access. Distinct UIDs also
              # prevent ptrace and access to one another's process environments.
              users.users = {
                agent-claude = {
                  isNormalUser = true;
                  homeMode = "0700";
                  description = "Claude fleet executor";
                };
                agent-codex = {
                  isNormalUser = true;
                  homeMode = "0700";
                  description = "Codex fleet executor";
                };
                agent-opencode = {
                  isNormalUser = true;
                  homeMode = "0700";
                  description = "opencode fleet executor";
                };
                agent-local = {
                  isNormalUser = true;
                  homeMode = "0700";
                  description = "credentialless local-model fleet executor";
                };
              };
              systemd.tmpfiles.rules = singleton "d /workspace 0770 root users -";

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
      # The fleet roster. Everything derived from a worker (the VM definition
      # and its slice fence) is generated from this one list.
      options.agentFleet = {
        workers = mkOption {
          description = "agent-fleet worker roster";
          default = [ ];
          type = types.listOf (
            types.submodule {
              options = {
                name = mkOption { type = types.str; };
                index = mkOption { type = types.ints.between 1 99; };
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

        # Fleet subscription credentials. The host drainer reads these paths at
        # dispatch time and stages only the credential selected by that task.
        credentials = {
          claudeTokenFile = mkOption {
            type = types.str;
            description = "host path of the Claude Code OAuth token (from `claude setup-token`)";
          };
          codexAuthFile = mkOption {
            type = types.str;
            description = "host path of a copy of Codex's auth.json (from a ChatGPT login)";
          };
          openrouterKeyFile = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "host path of an OpenRouter API key (single line, from openrouter.ai/keys); null = opencode dispatch has no credential and fails auth";
          };
        };
      };

      config = mkIf cfg.enable {
        assertions = [
          {
            assertion =
              lib.lists.length cfg.workers == lib.lists.length (lib.lists.unique (map (w: w.name) cfg.workers));
            message = "agentFleet worker names must be unique";
          }
          {
            assertion =
              lib.lists.length cfg.workers == lib.lists.length (lib.lists.unique (map (w: w.index) cfg.workers));
            message = "agentFleet worker indices must be unique";
          }
        ];

        microvm.vms = listToAttrs (map (w: nameValuePair w.name (mkAgentGuest w)) cfg.workers);

        # Share sources must exist before virtiofsd starts. The task exchange is
        # guest-writable; the credential source remains root-only and is empty
        # until the drainer stages one credential for a claimed task.
        systemd.tmpfiles.rules = concatMap (w: [
          "d ${workDir w.name} 0770 root users -"
          "d ${credsDir w.name} 0700 root root -"
        ]) cfg.workers;

        systemd.services = listToAttrs (
          map (
            w:
            # microvm.nix has no slice option; standard unit override so every
            # worker counts against the fleet's 48G/agents.slice fence.
            (nameValuePair "microvm@${w.name}" {
              serviceConfig = {
                Slice = "agents.slice";
                # The drainer owns worker lifecycle; upstream's Restart=always
                # (VMs as long-running services) would fight its stop/start.
                Restart = mkForce "no";
                # Don't attempt a graceful guest poweroff at all — the guest
                # is ephemeral (volumes are wiped on next start), so a clean
                # shutdown buys nothing and the guest's own poweroff is slow.
                # Dropping upstream's microvm-shutdown ExecStop and making
                # SIGKILL the *intended* kill signal means every stop is
                # instant AND records as success. (The previous shape —
                # ExecStop + TimeoutStopSec=3 — killed the VMM just as dead,
                # but systemd logged every stop as result=timeout, a FAILURE,
                # so each task recycle and every switch tripped the global
                # OnFailure Matrix alert: ten spurious alerts per switch.)
                # [ "" ] renders an empty `ExecStop=` assignment, which is
                # systemd's "reset the list" idiom — required because the
                # directive comes from the shared microvm@.service template
                # and a drop-in can only clear it explicitly.
                ExecStop = mkForce [ "" ];
                KillSignal = "SIGKILL";
                # systemd only treats the polite signals (TERM/HUP/INT/PIPE)
                # as clean deaths; dying by our own KillSignal must be
                # declared expected or the unit still records result=signal.
                SuccessExitStatus = "SIGKILL";
                TimeoutStopSec = mkForce 3; # vestigial backstop
                # EPHEMERALITY — delete the volume images before every start;
                # the runner's autoCreate recreates them blank (truncate +
                # mkfs), so each boot is a clean slate.
                ExecStartPre = singleton (
                  "${getExe' pkgs.coreutils "rm"} -f "
                  + concatMapStringsSep " " (v: "${config.microvm.stateDir}/${w.name}/${v.image}") volumes
                );
              };
            })
          ) cfg.workers
        );
      };
    };
}
