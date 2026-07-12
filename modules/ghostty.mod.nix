# Terminal. font-family is CaskaydiaMono Nerd Font (installed by
# fonts.mod.nix); ghostty uses its default theme.
{
  # Every host carries ghostty's terminfo (tiny), so SSH sessions from a
  # ghostty terminal (TERM=xterm-ghostty) work on servers too — without it,
  # tmux/less/etc. fail with "missing or unsuitable terminal".
  flake.nixosModules.ghostty-terminfo =
    { pkgs, ... }:
    {
      environment.systemPackages = [ pkgs.ghostty.terminfo ];
    };

  flake.homeModules.ghostty =
    {
      lib,
      osConfig,
      pkgs,
      ...
    }:
    let
      inherit (lib.modules) mkIf mkForce;
    in
    {
      config = mkIf osConfig.isDesktop {
        # Upstream's onChange hook runs `ghostty +validate-config` with no
        # error tolerance, and ghostty's user unit reloads via SIGUSR2
        # (Type=notify-reload). During activation that signal can land on the
        # short-lived validate process instead, killing the whole activation
        # (exit 140 = 128+SIGUSR2). The config is Nix-generated, so validation
        # is redundant: replace the hook with a non-fatal reload of the
        # running daemon (no-op when the user session/daemon isn't up).
        xdg.configFile."ghostty/config".onChange = mkForce ''
          ${pkgs.systemd}/bin/systemctl --user try-reload-or-restart app-com.mitchellh.ghostty.service 2>/dev/null || true
        '';

        programs.ghostty = {
          enable = true;

          settings = {
            # Interactive shell for terminal windows only. The LOGIN shell
            # stays POSIX (bash, the NixOS default): tools that shell out via
            # $SHELL (nvim's wildcard expansion, :!, lf, ...) break under
            # nushell.
            command = lib.meta.getExe pkgs.nushell;

            window-padding-x = 14;
            window-padding-y = 14;
            background-opacity = 0.95;
            window-decoration = "none";

            font-family = "CaskaydiaMono Nerd Font";
            font-size = 10;

            keybind = [ "ctrl+k=reset" ];
          };

          # Daemon flags (gtk-single-instance, initial-window, etc.) must not
          # live in the config file: that file is also read by every plain
          # `ghostty` invocation (e.g. the SUPER+RETURN keybind), and
          # initial-window=false there suppressed windows for normal launches.
          # Those flags belong only on the daemon's ExecStart, which is why we
          # use upstream's systemd unit (default `systemd.enable = true`)
          # instead of hand-rolling one. It's WantedBy=graphical-session.target
          # and After=graphical-session.target, which is safe now that UWSM
          # (not this module's own `hyprland-session.target` hook, which is
          # disabled — see `wayland.windowManager.hyprland.systemd` in
          # hyprland.mod.nix) brings up `graphical-session.target` only after
          # `uwsm finalize` has exported session vars.
        };
      };
    };
}
