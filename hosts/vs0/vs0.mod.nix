{ self, lib, ... }:
let
  inherit (lib.lists) singleton;
in
{
  imports = singleton (
    lib.systems.nixosSystem "vs0" (
      { config, lib, ... }:
      let
        inherit (lib.attrsets) attrValues;
        inherit (lib.lists) singleton;
      in
      {
        imports = attrValues self.commonModules ++ attrValues self.nixosModules;

        # HOST CLASS (server: isDesktop defaults to false, stated here for clarity)
        isDesktop = false;

        nixpkgs.hostPlatform = "x86_64-linux";

        # HARDWARE — PLACEHOLDER (generic VM). When the real vs0 exists: fix
        # the disk device (prefer /dev/disk/by-id/...), adjust the kernel
        # modules, then format + install with
        # `disko --mode disko --flake .#vs0` + `nixos-install --flake .#vs0`.
        boot.initrd.availableKernelModules = [
          "ahci"
          "xhci_pci"
          "virtio_pci"
          "virtio_scsi"
          "sd_mod"
          "sr_mod"
        ];
        boot.kernelModules = [ "kvm-amd" ];
        networking.useDHCP = lib.mkDefault true;

        disko.devices.disk.main = {
          device = "/dev/vda";
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
              type = "filesystem";
              format = "ext4";
              mountpoint = "/";
            };
          };
        };

        # SECRETS (create with `agenix -e hosts/vs0/<file>.age`)
        secrets.tailscale.file = ./tailscale.age;
        secrets.litellm.file = ./litellm.env.age;
        secrets."open-webui".file = ./open-webui.env.age;

        # TAILSCALE
        services.tailscale.authKeyFile = config.secrets.tailscale.path;

        # AI STACK ---------------------------------------------------------
        # LiteLLM gateway (localhost:4000). The model_list below is illustrative;
        # edit it for your providers. `os.environ/NAME` reads NAME from the
        # encrypted environmentFile (which must define LITELLM_MASTER_KEY and the
        # referenced provider keys).
        services.litellm.enable = true;
        services.litellm.environmentFile = config.secrets.litellm.path;
        services.litellm.settings.model_list = [
          {
            model_name = "gpt-4o";
            litellm_params = {
              model = "openai/gpt-4o";
              api_key = "os.environ/OPENAI_API_KEY";
            };
          }
          {
            model_name = "claude-sonnet";
            litellm_params = {
              model = "anthropic/claude-3-7-sonnet-latest";
              api_key = "os.environ/ANTHROPIC_API_KEY";
            };
          }
        ];

        # Open WebUI front-end. Its environmentFile must set OPENAI_API_KEY to the
        # SAME value as LiteLLM's LITELLM_MASTER_KEY, plus a WEBUI_SECRET_KEY.
        services.open-webui.enable = true;
        services.open-webui.environmentFile = config.secrets."open-webui".path;
        # ------------------------------------------------------------------

        system.stateVersion = "26.05";
      }
    )
  );
}
