# Graphical boot splash + LUKS prompt (Fedora-style). Plymouth exists to win
# the display race the text prompt loses: amdgpu's modeset completes ~1-2s
# into boot, asynchronously, and whether systemd-cryptsetup's console prompt
# lands before or after it is hardware timing (on fw3's drive it lost,
# leaving a stale pre-modeset frame with the passphrase echo drawn
# mid-screen). Plymouth watches DRM devices and repaints on driver takeover,
# so it can't be stranded. Early KMS is a prerequisite and already in place
# (nixos-hardware forces amdgpu into initrd.kernelModules).
{
  flake.nixosModules.plymouth =
    { config, lib, ... }:
    let
      inherit (lib.modules) mkDefault mkIf;
    in
    {
      config = mkIf config.isDesktop {
        boot.plymouth.enable = true;

        # A splash only stays clean if the console stops talking over it.
        boot.initrd.verbose = mkDefault false;
        boot.kernelParams = [
          "quiet"
          "udev.log_level=3"
        ];
      };
    };
}
