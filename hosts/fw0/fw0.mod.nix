# fw0 — Framework Desktop (Ryzen AI Max+ 395 "Strix Halo", 128GB unified
# LPDDR5X), repurposed as the headless always-on AI server. Roles per the
# agent-host plan: local LLM inference, agent-fleet microVM host (later
# phases), and the user's persistent cockpit session. Websites/Minecraft are
# deliberately out of scope. All admin and service access is tailnet-only —
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
    lib.systems.nixosSystem "fw0" (
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

        # DISK — PLACEHOLDER device. No LUKS: the host must auto-boot
        # unattended after a power loss and there is no console attached to
        # type a passphrase (revisit with TPM auto-unlock if encryption at
        # rest becomes a requirement).
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

          content.partitions.root = {
            priority = 200;
            size = "100%";

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

        # SLICES — coarse resource fences so no tenant starves another.
        # agents = worker microVMs + dispatcher (Phase 2+), inference = LLM
        # serving (Phase 6 declares the full mode tables; the ceilings below
        # are the fleet-mode budget), services = everything else (litellm,
        # open-webui, ...). CPUWeight stays at the default 100 for all —
        # equal shares under contention.
        systemd.slices.agents.sliceConfig.MemoryMax = "48G";
        systemd.slices.inference.sliceConfig.MemoryMax = "96G";
        systemd.slices.services.sliceConfig.MemoryMax = "16G";

        # SECRETS + AI STACK — DISABLED until real secrets exist.
        #
        # agenix decrypts every declared `secrets.<name>` during system
        # activation using the host key; the `.age` files here are still
        # AGENIX-PLACEHOLDER text (not real ciphertext), so declaring them
        # makes `nixos-rebuild switch` FAIL activation ("age: failed to read
        # header"). So nothing below is declared while the values are fake —
        # fw0 currently runs only as the cockpit + fleet host, which needs no
        # secrets. Tailscale still runs (enabled by default) and stays joined
        # via its persisted /var/lib/tailscale state; it just isn't re-auth'd
        # from a key here.
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
