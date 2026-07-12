# Fonts: CaskaydiaMono Nerd Font is what the ghostty/DMS configs reference.
# `noto-fonts-color-emoji` is the current attribute name (noto-fonts-emoji is
# a deprecated alias).
{
  flake.nixosModules.fonts =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      inherit (lib.modules) mkIf mkMerge;

      # Comic Code is a paid font, so the repo carries only agenix ciphertext
      # (a gzipped tar of the .otf files), decrypted at activation and
      # unpacked outside /nix/store — never plaintext in the repo or a
      # world-readable store path. TO CREATE THE SECRET:
      #
      #   tar czf /tmp/comic-code.tgz -C <dir containing the .otf files> .
      #   cd ~/ark/monix && EDITOR="cp /tmp/comic-code.tgz" agenix -e fonts/comic-code.age
      #   git add fonts/comic-code.age && rm /tmp/comic-code.tgz
      #
      # The whole block is gated on the (git-tracked) ciphertext existing, so
      # clones without the secret still evaluate.
      comicCodeAge = ../../fonts/comic-code.age;
      hasComicCode = builtins.pathExists comicCodeAge;
    in
    {
      config = mkIf config.isDesktop (mkMerge [
        (mkIf hasComicCode {
          secrets.comic-code.file = comicCodeAge;

          system.activationScripts.comic-code-fonts = {
            deps = [ "agenixInstall" ];
            text = ''
              rm -rf /var/lib/fonts/comic-code
              mkdir -p /var/lib/fonts/comic-code
              # activation runs with a minimal PATH: tar can't shell out to a
              # gzip it can't find, so hand it the store path explicitly
              ${pkgs.gnutar}/bin/tar --use-compress-program=${pkgs.gzip}/bin/gzip \
                -xf "${config.secrets.comic-code.path}" -C /var/lib/fonts/comic-code
              chmod -R a+rX /var/lib/fonts/comic-code
            '';
          };

          # fonts.packages only takes store paths, so the decrypted dir is
          # handed to fontconfig directly instead.
          fonts.fontconfig.localConf = ''
            <?xml version="1.0"?>
            <!DOCTYPE fontconfig SYSTEM "fonts.dtd">
            <fontconfig>
              <dir>/var/lib/fonts</dir>
            </fontconfig>
          '';
        })
        {
          fonts.enableDefaultPackages = true;

          fonts.packages = [
            pkgs.noto-fonts
            pkgs.noto-fonts-color-emoji
            pkgs.nerd-fonts.caskaydia-mono
          ];

          fonts.fontconfig.defaultFonts = {
            monospace = [ "CaskaydiaMono Nerd Font" ];
            sansSerif = [ "Noto Sans" ];
            serif = [ "Noto Serif" ];
            emoji = [ "Noto Color Emoji" ];
          };
        }
      ]);
    };
}
