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
      { config, lib, pkgs, ... }:
      let
        inherit (lib.attrsets) attrValues;
        inherit (lib.lists) singleton;
      in
      {
        imports =
          attrValues self.commonModules
          ++ attrValues self.nixosModules
          ++ singleton inputs.nixos-hardware.nixosModules.framework-desktop-amd-ai-max-300-series;

        # HOST CLASS
        isDesktop = true;

        nixpkgs.hostPlatform = "x86_64-linux";

        # HARDWARE — Framework Desktop, Ryzen AI Max+ 395 (Strix Halo), 128GB.
        # CPU/GPU/pstate/microcode come from the nixos-hardware profile above.
        # Kernel-module list is a reasonable guess until the machine exists;
        # verify with `nixos-generate-config --show-hardware-config` on it.
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
        networking.useDHCP = lib.mkDefault true;

        boot.kernelPackages = pkgs.linuxPackages_zen;

        # No laptop power management here on purpose: no powertop/runtime-PM
        # tuning, no backlight/ABM kernel params, no lid or battery concerns.
        # Desktop stays on defaults (amd_pstate from the profile).

        # DISK — PLACEHOLDER. Same scheme as fw3 (ESP + LUKS "cryptroot" +
        # btrfs subvol @). Point `device` at the real NVMe's
        # /dev/disk/by-id/... before installing with
        # `disko --mode disko --flake .#fw0` + `nixos-install --flake .#fw0`.
        disko.devices.disk.main = {
          device = "/dev/disk/by-id/CHANGEME";
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

        # PERIPHERALS
        hardware.keyboard.zsa.enable = true;

        # SERVICES
        services.syncthing.enable = true;
        services.printing.enable = true;

        # DESKTOP EXTRAS
        programs.steam.enable = true;

        system.stateVersion = "26.05";
      }
    )
  );
}
