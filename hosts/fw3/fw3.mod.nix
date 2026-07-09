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
    lib.monix.nixosSystem "fw3" (
      { lib, pkgs, ... }:
      let
        inherit (lib.attrsets) attrValues;
        inherit (lib.lists) singleton;
        inherit (lib.modules) mkForce;
      in
      {
        imports =
          attrValues self.commonModules
          ++ attrValues self.nixosModules
          ++ singleton inputs.nixos-hardware.nixosModules.framework-13-7040-amd;

        # HOST CLASS
        isDesktop = true;

        nixpkgs.hostPlatform = "x86_64-linux";

        # HARDWARE (quirks/power tuning come from the nixos-hardware
        # framework module above)
        boot.initrd.availableKernelModules = [
          "nvme"
          "xhci_pci"
          "thunderbolt"
          "usb_storage"
          "uas"
          "sd_mod"
        ];
        boot.kernelModules = [ "kvm-amd" ];
        hardware.enableRedistributableFirmware = true;
        hardware.cpu.amd.updateMicrocode = true;
        networking.useDHCP = lib.mkDefault true;

        # DISK (WD Black SN850X 2TB). Disko derives the mount config: /boot
        # from the ESP, / from btrfs subvol @ inside LUKS (opened as
        # /dev/mapper/cryptroot). Partlabels disk-main-boot/disk-main-luks are
        # set by disko on a fresh format; the pre-disko install needed them
        # set once by hand (sgdisk --change-name).
        disko.devices.disk.main = {
          device = "/dev/disk/by-id/nvme-WD_BLACK_SN850X_2000GB_24144X801841";
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

              content = {
                type = "btrfs";
                subvolumes."@" = {
                  mountpoint = "/";
                };
              };
            };
          };
        };

        # POWER (amd_pstate and the amdgpu PSR workaround come from
        # nixos-hardware and are not repeated here)
        boot.kernelPackages = pkgs.linuxPackages_zen;

        boot.kernelParams = [
          "amdgpu.runpm=1"
          "video.use_native_backlight=1"
          "amdgpu.abmlevel=1"
        ];

        boot.kernel.sysctl = {
          "kernel.nmi_watchdog" = 0;
          "kernel.timer_migration" = 1;
        };

        powerManagement.enable = true;
        powerManagement.powertop.enable = true;

        services.logind.settings.Login.HandlePowerKey = "suspend";

        systemd.timers."fwupd-refresh".enable = false;

        # FRAMEWORK QUIRKS
        hardware.framework.enableKmod = mkForce false;
        hardware.sensor.iio.enable = false;
        hardware.fw-fanctrl.enable = true;

        # PERIPHERALS
        hardware.keyboard.zsa.enable = true;

        # SERVICES
        services.syncthing.enable = true;
        services.printing.enable = true;

        # DESKTOP EXTRAS
        programs.steam.enable = true;

        # Minecraft client, for the fw0 tailnet server (see
        # modules/server/minecraft.mod.nix). Prism over the stock launcher:
        # trivial to pin a client instance to the server's exact Minecraft
        # version, which the server tracks behind latest (mod availability).
        environment.systemPackages = singleton pkgs.prismlauncher;

        # USER: login shell is NixOS's default (bash) — a plain POSIX $SHELL
        # for tools that shell out (nvim, lf, tmux). The interactive shell is
        # nushell, launched by ghostty (see ghostty.mod.nix).

        system.stateVersion = "26.05";
      }
    )
  );
}
