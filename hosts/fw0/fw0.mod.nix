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

        # The primary interactive Claude session lives here (tmux over
        # tailnet SSH); any machine is just a terminal into it.
        cockpit.enable = true;

        # Agent-fleet microVM host. Brings up the host-only bridge +
        # egress proxy + microvm.nix runner (see microvm-host.mod.nix).
        agentFleet.enable = true;

        # FLEET CREDENTIALS — subscription logins shared by all workers,
        # as agenix secrets; create/refresh with `agenix -e
        # hosts/fw0/<name>.age` from the repo root (the agenix CLI ships on
        # cockpit hosts). No push credential yet: when the worker should
        # push, create a fine-grained PAT scoped to exactly its repo
        # (Contents read/write on that repo only; a forge ruleset protects
        # main and allows agent/** pushes), encrypt it as
        # hosts/fw0/agent-lfish-pat.age (currently a placeholder), declare
        # it like the secrets below, and set the worker's `patFile`.
        secrets.agent-claude-token.file = ./agent-claude-token.age;
        secrets.agent-codex-auth.file = ./agent-codex-auth.age;

        agentFleet.credentials = {
          claudeTokenFile = config.secrets.agent-claude-token.path;
          codexAuthFile = config.secrets.agent-codex-auth.path;
        };

        agentFleet.workers = singleton {
          name = "lfish-0";
          index = 1;
          repo = "cdland/lfish";
        };

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
        # secrets — `agenix -e hosts/fw0/litellm.env.age` etc. (the host key
        # in keys.nix is real now) — then uncomment the matching block(s).
        #
        # secrets.tailscale.file = ./tailscale.age;
        # secrets.litellm.file = ./litellm.env.age;
        # secrets."open-webui".file = ./open-webui.env.age;
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
