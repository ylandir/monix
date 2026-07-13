# Interactive shell = nushell, login/$SHELL = bash — on headless hosts.
#
# The desktop delivers this split through ghostty (its window command is nu
# while $SHELL stays bash, so tools that shell out via $SHELL — nvim's `:!`,
# lf's `w`, … — keep working; see ghostty.mod.nix). A headless host has no
# ghostty, so an interactive login lands in bash while lf's `w` still opens
# nu — the inconsistency this fixes. Here bash's interactive init re-execs
# into nu, giving the same result without changing the login shell: $SHELL
# and non-interactive shells stay POSIX bash (scripts, `ssh host 'cmd'`, and
# the cockpit's own tool calls are unaffected), only interactive sessions
# become nu.
#
# Gated to non-desktops so fw3 keeps the ghostty path untouched.
{
  flake.homeModules.interactive-shell =
    { lib, osConfig, ... }:
    {
      config = lib.mkIf (!osConfig.isDesktop) {
        programs.bash = {
          enable = true;
          # Guards: only interactive shells ($- has i), only once (SHIP_NU is
          # exported before the exec and inherited by nu, so a bash launched
          # from within nu stays bash), and only when nu is actually present.
          initExtra = ''
            if [[ $- == *i* ]] && [[ -z "''${SHIP_NU:-}" ]] && command -v nu >/dev/null 2>&1; then
              export SHIP_NU=1
              exec nu
            fi
          '';
        };
      };
    };
}
