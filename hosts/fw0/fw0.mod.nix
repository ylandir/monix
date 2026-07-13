# fw0 — Framework Desktop (Ryzen AI Max+ 395 "Strix Halo", 128GB unified
# LPDDR5X), the headless always-on AI server. Roles: agent-fleet microVM
# host (see docs/agent-fleet.md), the user's persistent cockpit session,
# and the LiteLLM/Open WebUI gateway (declared but disabled below until
# real secrets exist). All admin and service access is tailnet-only —
# zero inbound ports on the home IP (public SSH is closed by ssh.mod.nix for
# servers; every service binds localhost or is reached via the trusted
# tailscale0 interface).
#
# BIOS (one-time, manual): enable AMD SVM (virtualization) and "restore on AC
# power loss" so the host auto-boots after an outage.
{
  self,
  inputs,
  lib,
  ...
}:
let
  inherit (lib.lists) singleton;
in
{
  imports = singleton (
    lib.monix.nixosSystem "fw0" (
      { config, lib, ... }:
      let
        inherit (lib.attrsets) attrValues;
        inherit (lib.lists) singleton;
      in
      {
        imports =
          attrValues self.commonModules
          ++ attrValues self.nixosModules
          ++ singleton inputs.nixos-hardware.nixosModules.framework-desktop-amd-ai-max-300-series;

        # HOST CLASS (server: isDesktop defaults to false, stated for clarity)
        isDesktop = false;

        primaryUser = "max";

        # Declarative login password, same shape and rationale as fw3 (see
        # the comment in fw3.mod.nix). Deliberately NOT gated on the .age
        # existing: past bootstrap, a missing secret should be a loud eval
        # error, not a silent fallback to mutable users.
        users.mutableUsers = false;
        users.users.${config.primaryUser}.hashedPasswordFile =
          config.secrets.max-password.path;

        # The primary interactive agent cockpit lives here; frontends include
        # tmux over tailnet SSH and opencode web through Cloudflare Access.
        cockpit.enable = true;

        # Agent-fleet microVM host. Brings up the host-only bridge +
        # egress proxy + microvm.nix runner (see microvm-host.mod.nix).
        agentFleet.enable = true;

        # Matrix alerting (alerts.mod.nix): unit failures and the 6-hourly
        # sweep post to the Ship Alerts room on the local tuwunel as
        # @alertbot. Live since 2026-07-12; deliberately NOT gated on the
        # .age existing — past bootstrap, a missing secret should be a loud
        # eval error, not silently-disabled alerting.
        alerts.enable = true;
        alerts.credentialsEnvFile = config.secrets.matrix-alertbot-env.path;

        # Fleet ops feed (fleet-log-stream.mod.nix): the agent-fleet audit
        # log streamed line-for-line into a Fleet Ops room, posted by the
        # same alertbot account. The bot creates the room on first start
        # and invites the captain.
        fleetLogStream.enable = true;
        fleetLogStream.credentialsEnvFile = config.secrets.matrix-alertbot-env.path;
        fleetLogStream.inviteUsers = [ "@dylan:chat.su.is" ];

        # Usage/cost ledger CLI (ship-costs.mod.nix). The OpenRouter section
        # is bootstrap-gated: create a read-only management key at
        # openrouter.ai Settings → Management Keys, then
        # `agenix -e hosts/fw0/secrets/openrouter-management-key.age`
        # (rule already in secrets.nix), git add, switch.
        shipCosts.enable = true;
        shipCosts.openrouterKeyFile =
          if builtins.pathExists ./secrets/openrouter-management-key.age then
            config.secrets.openrouter-management-key.path
          else
            null;
        # Plain-language line atop failure alerts, from the ship-local model
        # (free, loopback; degrades to the raw alert if inference is down).
        alerts.summary.enable = true;

        # Declarative Fabric Minecraft server (see minecraft.mod.nix). Fabric
        # 26.1.2, server-side mods only, ~4G heap in services.slice. Tailnet-only
        # (openFirewall = false) and egress-fenced so a compromised server can't
        # pivot onto localhost, the LAN, or the fleet bridge.
        minecraft.enable = true;

        # Local inference: llama.cpp (Vulkan) behind llama-swap on :8091,
        # tailnet-only, models load on demand and unload after idle
        # (inference.mod.nix). The first catalog model is a 35B-total/3B-active
        # Qwen MoE: a fast general coding and agent model that leaves ample
        # memory for context and host services within the 96 GiB GTT fence.
        inference.enable = true;
        inference.models."qwen3.6-35b-a3b" = {
          file = "Qwen3.6-35B-A3B-UD-Q5_K_XL.gguf";
          flags = [ "-c" "65536" "--flash-attn" "on" "--jinja" ];
          aliases = [ "qwen3.6" ];
        };
        # The large local reasoning model: 117B-total/5.1B-active MoE in its
        # native MXFP4 (~63G on disk, ~68G resident at full 128K context —
        # inside the 96G GTT fence, but only after the GTT kernel params have
        # taken effect on a reboot). Split GGUF: llama-server takes the first
        # part and finds the rest. --jinja applies the embedded Harmony chat
        # template, which gpt-oss requires.
        inference.models."gpt-oss-120b" = {
          file = "gpt-oss-120b-mxfp4-00001-of-00003.gguf";
          flags = [ "-c" "131072" "--flash-attn" "on" "--jinja" ];
          aliases = [ "gpt-oss" ];
        };

        # Family budgeting: Actual Budget on :5006 (actual.mod.nix) —
        # tailnet-direct, plus budget web access through the existing
        # Cloudflare tunnel connector (public hostname + Access policy are
        # dashboard-side). Egress-fenced to loopback+tailnet; no bank sync.
        actual.enable = true;
        # Budget web seat rides its own Cloudflare tunnel (separate from the
        # cockpit's) so its exposure is independently revocable; hostname +
        # Access policy live in the Zero Trust dashboard.
        actual.tunnelTokenFile = config.secrets.actual-cloudflare-tunnel-token.path;

        # Family Matrix homeserver (matrix.mod.nix): tuwunel, federation
        # OFF, token-gated registration, chat.su.is through its own
        # Cloudflare tunnel (NO Access app — Matrix does its own auth).
        # The chat rail for the family and, later, the assistant bot.
        matrix.enable = true;
        matrix.serverName = "chat.su.is";
        matrix.registrationTokenEnvFile = config.secrets.matrix-registration-env.path;
        # Gated on the .age existing so the config builds before the
        # captain has created the tunnel and provided its token.
        matrix.tunnelTokenFile =
          if builtins.pathExists ./secrets/matrix-cloudflare-tunnel-token.age then
            config.secrets.matrix-cloudflare-tunnel-token.path
          else
            null;

        # The family chat bot remy (remy.mod.nix): household organizer —
        # tasks, lists, 07:00/19:00 day-plan posts — in a "Household" room
        # it creates itself (family invited below), PLUS the absorbed
        # budgetbot skill set in the existing Budget room against the
        # unchanged ledger. Account auto-registers from the registration
        # token; the retired budgetbot account invites remy into the
        # Budget room via the adopt oneshot. Loopback-only.
        remy.enable = true;
        remy.credentialsEnvFile = config.secrets.matrix-remy-env.path;
        remy.registrationEnvFile = config.secrets.matrix-registration-env.path;
        remy.budgetRoomId = "!pSYRAx0dRdSkbxwgPr:chat.su.is";
        remy.budgetbotEnvFile = config.secrets.matrix-budgetbot-env.path;
        remy.inviteUsers = [
          "@dylan:chat.su.is"
          "@gab:chat.su.is"
        ];
        # Migadu CalDAV section in the daily posts — bootstrap-gated: create
        # the JSON secret (see the option's description) as
        # hosts/fw0/secrets/remy-caldav.json.age, git add, switch.
        remy.calendar.credentialsFile =
          if builtins.pathExists ./secrets/remy-caldav.json.age then
            config.secrets.remy-caldav-json.path
          else
            null;

        # opencode web UI cockpit seat, exposed through Cloudflare Tunnel.
        # Authentication belongs at the Cloudflare Access layer; do not set
        # cockpit.webEnvFile here unless deliberately re-enabling opencode's
        # app-local Basic auth.
        cockpit.webEnable = true;
        # The system service does not inherit a login shell's config lookup.
        # Point it at the cockpit's local-model provider configuration.
        systemd.services.opencode-web.serviceConfig.Environment = [
          "OPENCODE_CONFIG=/home/max/.config/opencode/opencode.jsonc"
        ];
        # Public opencode web cockpit over Cloudflare Tunnel. The token comes
        # from Zero Trust's "Install and run a connector" command for tunnel
        # 8ad1eab3-29bc-4d27-8ab8-163b4097e9e0. In Cloudflare, configure the
        # public hostname ai.su.is to route to http://127.0.0.1:4096.
        cockpit.webTunnelTokenFile = config.secrets.opencode-web-cloudflare-tunnel-token.path;

        # FLEET CREDENTIALS — subscription logins available in every VM but
        # isolated into executor-specific Unix users; create/refresh with `agenix -e
        # hosts/fw0/secrets/<name>.age` from the repo root (the agenix CLI ships on
        # cockpit hosts). Workers have no forge route or credentials: source
        # context goes in as a capsule and results come back over the task share.
        secrets = {
          # Login password hash (see the declarative-password comment above).
          max-password.file = ./secrets/max-password.age;

          agent-claude-token.file = ./secrets/agent-claude-token.age;
          agent-codex-auth.file = ./secrets/agent-codex-auth.age;
        }
        // lib.optionalAttrs (builtins.pathExists ./secrets/agent-openrouter-key.age) {
          agent-openrouter-key.file = ./secrets/agent-openrouter-key.age;
        }
        // lib.optionalAttrs (builtins.pathExists ./secrets/opencode-web-env.age) {
          opencode-web-env.file = ./secrets/opencode-web-env.age;
        }
        // {
          opencode-web-cloudflare-tunnel-token = {
            file = ./secrets/opencode-web-cloudflare-tunnel-token.age;
          };
          actual-cloudflare-tunnel-token = {
            file = ./secrets/actual-cloudflare-tunnel-token.age;
          };
          matrix-registration-env = {
            file = ./secrets/matrix-registration.env.age;
          };
          # The RETIRED budgetbot account — kept only for remy's
          # adopt-budget-room oneshot (see remy wiring above).
          matrix-budgetbot-env = {
            file = ./secrets/matrix-budgetbot.env.age;
          };
          matrix-remy-env = {
            file = ./secrets/matrix-remy.env.age;
          };
        }
        // lib.optionalAttrs (builtins.pathExists ./secrets/remy-caldav.json.age) {
          # Migadu CalDAV accounts for remy's calendar sections (JSON
          # list; see remy.calendar.credentialsFile). Readable only by
          # the sync unit's user.
          remy-caldav-json = {
            file = ./secrets/remy-caldav.json.age;
            owner = "remy";
          };
        }
        // lib.optionalAttrs (builtins.pathExists ./secrets/matrix-cloudflare-tunnel-token.age) {
          matrix-cloudflare-tunnel-token = {
            file = ./secrets/matrix-cloudflare-tunnel-token.age;
          };
        }
        // {
          # The alert bot's Matrix account + room (see alerts wiring above).
          matrix-alertbot-env.file = ./secrets/matrix-alertbot.env.age;
        }
        // lib.optionalAttrs (builtins.pathExists ./secrets/openrouter-management-key.age) {
          # Read-only OpenRouter management key for ship-costs' exact-spend
          # section; owned by the primary user, who runs ship-costs.
          openrouter-management-key = {
            file = ./secrets/openrouter-management-key.age;
            owner = config.primaryUser;
          };
        };

        # agenix in this input has no restartUnits option; make the encrypted
        # source an explicit unit trigger so token rotation restarts cloudflared.
        systemd.services.opencode-web-tunnel.restartTriggers = [
          ./secrets/opencode-web-cloudflare-tunnel-token.age
        ];
        systemd.services.actual-tunnel.restartTriggers = [
          ./secrets/actual-cloudflare-tunnel-token.age
        ];
        systemd.services.matrix-tunnel.restartTriggers = [
          ./secrets/matrix-cloudflare-tunnel-token.age
        ];

        agentFleet.credentials = {
          claudeTokenFile = config.secrets.agent-claude-token.path;
          codexAuthFile = config.secrets.agent-codex-auth.path;
        }
        # OpenRouter API key for `agent: opencode` (pay-per-token, any model
        # on the catalog). Gated on the .age file existing (and being
        # committed — flake source is the git tree) so the config builds
        # before the key is provisioned; create it with
        # `agenix -e hosts/fw0/secrets/agent-openrouter-key.age`, then `git add`.
        // lib.optionalAttrs (builtins.pathExists ./secrets/agent-openrouter-key.age) {
          openrouterKeyFile = config.secrets.agent-openrouter-key.path;
        };

        # Generic sealed workers: every worker boots idle and waits for a
        # cockpit-supplied task capsule (see
        # agent-vm.mod.nix), so keep MORE than typical demand — an incoming task
        # grabs one that's already up instead of waiting on a ~50s boot. Idle
        # guests are cheap (cloud-hypervisor demand-pages RAM; an idle guest
        # holds only a few hundred MB), and the fleet's real usage is capped
        # fleet-wide by the agents.slice budget. Pool size is just this number.
        # The eight drones, each named for a genus of bird-of-paradise
        # (Paradisaeidae) — one per distinct initial letter in the family
        # (A C D E L M P S), so no two share a first letter. No roster digit
        # in the name. Names feed tap interface ids ("vm-<name>", kernel cap
        # 15 chars); all fit. Crew of ten: captain, engineer, eight drones.
        # (Ship name TBD — Astrapia, once reserved for the vessel, now flies
        # as a drone.)
        agentFleet.workers = lib.lists.imap1 (index: name: { inherit name index; }) [
          "astrapia"
          "cicinnurus"
          "drepanornis"
          "epimachus"
          "lophorina"
          "manucodia"
          "paradisaea"
          "seleucidis"
        ];

        # BOOTSTRAP LOGIN — no password is committed here (this repo is
        # public, and `max` is the wheel/sudo account). On a fresh install,
        # set the password from the installer before the first boot:
        #   `nixos-enter --root /mnt -c 'passwd max'`
        # then log in at the console and `sudo tailscale up`. On the running
        # host the password is already set imperatively (users.mod.nix).

        nixpkgs.hostPlatform = "x86_64-linux";

        # HARDWARE — CPU/GPU/pstate/microcode come from the nixos-hardware
        # profile above. Kernel-module list taken from
        # `nixos-generate-config --show-hardware-config` on the machine.
        boot.initrd.availableKernelModules = [
          "nvme"
          "xhci_pci"
          "thunderbolt"
          "usbhid"
          "usb_storage"
          "sd_mod"
        ];
        boot.kernelModules = [ "kvm-amd" ];
        hardware.enableRedistributableFirmware = true;
        networking.useDHCP = lib.mkDefault true;

        # ENCRYPTED ROOT with TPM2 auto-unlock. The btrfs root lives inside a
        # LUKS container ("cryptroot"); the decryption key is sealed into the
        # board's TPM (enrolled once, post-install, with
        # `systemd-cryptenroll --tpm2-device=auto /dev/<root-part>`), so the
        # host still auto-boots headless after a power loss — the TPM releases
        # the key with no passphrase. A pull-the-drive attacker gets only
        # ciphertext (no TPM, no key). A LUKS passphrase slot is kept at format
        # time as the recovery key (used if the TPM state is ever cleared,
        # e.g. by a firmware reset); store it somewhere safe off-box.
        #
        # `crypttab-extra-opts tpm2-device=auto` makes the systemd-based initrd
        # try the TPM first. It requires `boot.initrd.systemd.enable` (below).
        # NOTE: enroll the TPM in the installer BEFORE the first reboot, or the
        # first headless boot will hang waiting for the passphrase.
        boot.initrd.systemd.enable = true;

        disko.devices.disk.main = {
          device = "/dev/disk/by-id/nvme-Samsung_SSD_980_PRO_with_Heatsink_2TB_S6WRNS0T219958J";
          type = "disk";

          content.type = "gpt";

          content.partitions.boot = {
            priority = 100;
            size = "1G";
            type = "EF00";

            content = {
              type = "filesystem";
              format = "vfat";
              mountpoint = "/boot";
              mountOptions = [
                "fmask=0077"
                "dmask=0077"
              ];
            };
          };

          content.partitions.luks = {
            priority = 200;
            size = "100%";

            content = {
              type = "luks";
              name = "cryptroot";

              # Read at format time only (a temp recovery passphrase the
              # installer writes here); never committed. TPM enrollment
              # replaces it as the normal unlock path.
              passwordFile = "/tmp/luks.key";

              settings = {
                allowDiscards = true;
                crypttabExtraOpts = [ "tpm2-device=auto" ];
              };

              content = {
                type = "btrfs";

                # Dedicated datasets so the agent subsystem (scratch images,
                # session logs, caches) and model weights are separable and
                # snapshot/quota-able independently of the root.
                subvolumes."@" = {
                  mountpoint = "/";
                };
                subvolumes."@agents" = {
                  mountpoint = "/var/lib/agents";
                };
                subvolumes."@models" = {
                  mountpoint = "/var/lib/models";
                };
              };
            };
          };
        };

        # SLICES — coarse resource fences so no tenant starves another.
        # agents = the worker microVMs + squid, inference = local LLM
        # serving, services = everything else (litellm, open-webui, ...).
        # CPUWeight stays at the default 100 for all — equal shares under
        # contention.
        systemd.slices.agents.sliceConfig.MemoryMax = "48G";
        systemd.slices.inference.sliceConfig.MemoryMax = "96G";
        systemd.slices.services.sliceConfig.MemoryMax = "16G";

        # AI GATEWAY STACK — DISABLED until real secrets exist.
        #
        # agenix decrypts every declared `secrets.<name>` during system
        # activation using the host key; the `.age` files below are still
        # AGENIX-PLACEHOLDER text (not real ciphertext), so declaring them
        # makes `nixos-rebuild switch` FAIL activation ("age: failed to read
        # header"). So nothing below is declared while the values are fake.
        # Tailscale still runs (enabled by default) and stays joined via its
        # persisted /var/lib/tailscale state; it just isn't re-auth'd from a
        # key here.
        #
        # TO RE-ENABLE (when you actually want the local LiteLLM/Open WebUI
        # AI gateway, or key-based tailscale re-auth): create the real
        # secrets — `agenix -e hosts/fw0/secrets/litellm.env.age` etc. (the host key
        # in keys.nix is real now) — then uncomment the matching block(s).
        #
        # secrets.tailscale.file = ./secrets/tailscale.age;
        # secrets.litellm.file = ./secrets/litellm.env.age;
        # secrets."open-webui".file = ./secrets/open-webui.env.age;
        #
        # services.tailscale.authKeyFile = config.secrets.tailscale.path;
        #
        # services.litellm.enable = true;
        # services.litellm.environmentFile = config.secrets.litellm.path;
        # services.litellm.settings.model_list = [
        #   {
        #     model_name = "claude-opus";
        #     litellm_params = {
        #       model = "anthropic/claude-opus-4-8";
        #       api_key = "os.environ/ANTHROPIC_API_KEY";
        #     };
        #   }
        #   {
        #     model_name = "claude-sonnet";
        #     litellm_params = {
        #       model = "anthropic/claude-sonnet-4-6";
        #       api_key = "os.environ/ANTHROPIC_API_KEY";
        #     };
        #   }
        # ];
        # systemd.services.litellm.serviceConfig.Slice = "services.slice";
        #
        # services.open-webui.enable = true;
        # services.open-webui.environmentFile = config.secrets."open-webui".path;
        # systemd.services.open-webui.serviceConfig.Slice = "services.slice";

        system.stateVersion = "26.05";
      }
    )
  );
}
