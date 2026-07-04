# lf file manager. `open` (Enter/l on a file) picks by mime type: text-like
# files open in $EDITOR (nvim) in the same terminal; everything else is
# dispatched async to xdg-open, which resolves the desktop's mime handlers
# (browser, libreoffice, obsidian, ...). On the server there is no xdg-open,
# so non-text files simply don't open — fine for a headless host.
{
  flake.homeModules.lf =
    { pkgs, ... }:
    {
      programs.lf = {
        enable = true;

        # `w` spawns $SHELL by default, which is deliberately bash (POSIX
        # login shell). The interactive shell is nushell, so point w there.
        keybindings.w = "$" + "${pkgs.nushell}/bin/nu";

        commands.open = ''
          ''${{
            case $(${pkgs.file}/bin/file --mime-type -Lb "$f") in
              text/* | application/json | application/javascript | application/x-shellscript | application/toml | application/yaml | application/xml | inode/x-empty)
                $EDITOR $fx
                ;;
              *)
                for f in $fx; do
                  setsid -f xdg-open "$f" >/dev/null 2>&1
                done
                ;;
            esac
          }}
        '';
      };
    };
}
