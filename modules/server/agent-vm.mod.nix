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
{ self, ... }:
{
  flake.nixosModules.agent-guests =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      inherit (lib.attrsets) listToAttrs nameValuePair;
      inherit (lib.lists) concatMap singleton;
      inherit (lib.meta) getExe';
      inherit (lib.modules) mkIf;
      inherit (lib.options) mkOption;
      inherit (lib.strings) concatMapStringsSep fixedWidthString optionalString;
      inherit (lib) types;

      cfg = config.agentFleet;

      hostAddr = "10.100.0.1";
      proxyUrl = "http://${hostAddr}:3128";

      credsDir = name: "/run/agents/creds/${name}";
      guestCredsMount = "/run/host-creds";

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
                # The one repo this worker class works on and pushes to.
                AGENT_REPO = "https://github.com/${repo}.git";
              };

              environment.systemPackages = [
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
              # nothing else. Keyed to the admin keys: the human cockpit
              # session is the dispatcher.
              users.users.agent = {
                isNormalUser = true;
                description = "fleet worker";
                openssh.authorizedKeys.keys = self.keys-admin;
              };
              systemd.tmpfiles.rules = singleton "d /workspace 0755 agent users -";

              services.openssh = {
                enable = true;
                settings.PermitRootLogin = "no";
                settings.PasswordAuthentication = false;
              };

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
                  type = types.str;
                  example = "cdland/lfish";
                  description = "GitHub owner/repo this worker class is bound to";
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

        systemd.services = listToAttrs (
          concatMap (w: [
            # microvm.nix has no slice option; standard unit override so every
            # worker counts against the fleet's 48G/agents.slice fence.
            (nameValuePair "microvm@${w.name}" {
              serviceConfig = {
                Slice = "agents.slice";
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
