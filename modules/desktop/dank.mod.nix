# DankMaterialShell: one quickshell-based desktop shell providing the bar,
# notifications, launcher (spotlight), OSD, control center, lock screen with
# idle handling, wallpaper manager, clipboard history, and polkit agent. It
# replaces the previous waybar/mako/tofi/hyprpaper/hyprlock/hypridle/clipse
# aspects. Started from Hyprland via `dms run` (see hyprland.mod.nix).
#
# The shell itself stays on nixpkgs' `programs.dms-shell` module. The
# `dank-material-shell` flake input is used only for its `nixosModules.greeter`
# (nixpkgs does not ship a DMS greetd greeter) — `programs.dank-material-shell`
# (the flake's own shell option) is deliberately left disabled so we don't run
# two DMS shells.
{ inputs, ... }:
{
  flake.nixosModules.dank =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      inherit (lib.modules) mkIf;
      inherit (lib.lists) singleton;
    in
    {
      imports = singleton inputs.dank-material-shell.nixosModules.greeter;

      config = mkIf config.isDesktop {
        programs.dms-shell.enable = true;

        # nixpkgs' dms-shell (1.4.6) predates Hyprland 0.55's Lua-only command
        # socket: it dispatches old-style strings ("workspace 2"), which the
        # socket rejects, so bar workspace clicking/scrolling silently fails.
        # The flake's master build speaks the new API (hl.dsp.focus{...}).
        programs.dms-shell.package =
          inputs.dank-material-shell.packages.${pkgs.stdenv.hostPlatform.system}.dms-shell;

        # Wallpaper-synced app theming (Settings -> Theme & Colors -> "Apply
        # GTK/Qt Themes"). enableDynamicTheming provides matugen; adw-gtk3 is
        # the GTK theme DMS's generated gtk.css targets; kdePackages.qt6ct is
        # the qt6ct-kde fork (plain qt6ct can't read the KColorScheme file DMS
        # generates); qt5ct covers remaining Qt5 apps. DMS owns the generated
        # files at runtime (gtk.css, qt5ct/qt6ct configs, color schemes) —
        # nothing under home-manager may manage those paths.
        programs.dms-shell.enableDynamicTheming = true;
        environment.systemPackages = [
          pkgs.adw-gtk3
          pkgs.kdePackages.qt6ct
          pkgs.libsForQt5.qt5ct
        ];

        programs.dank-material-shell.greeter = {
          enable = true;
          compositor.name = "hyprland";

          # dms-greeter's built-in default Hyprland config disables the logo
          # but not the splash text/quote, so it still flashes before the
          # greeter UI renders. Passing customConfig REPLACES that default
          # entirely (the greeter script only ever appends its own
          # `exec-once = sh -c "$QS_CMD; hyprctl dispatch exit"` line after
          # it), so we reproduce the default here and add
          # disable_splash_rendering.
          compositor.customConfig = ''
            env = DMS_RUN_GREETER,1

            misc {
                disable_hyprland_logo = true
                disable_splash_rendering = true
            }
          '';
        };

        # Quickshell's battery service reads UPower; without the daemon the
        # DMS bar always shows AC power.
        services.upower.enable = true;

        # systemd user units don't inherit the session's XDG_DATA_DIRS on
        # NixOS; without it the DMS launcher finds no .desktop entries.
        systemd.user.services.dms.environment.XDG_DATA_DIRS =
          "/etc/profiles/per-user/${config.primaryUser}/share:/run/current-system/sw/share";

        # DMS's theming tab errors with "Missing Environment Variables" unless
        # the shell process itself sees the Qt platform theme it manages.
        systemd.user.services.dms.environment.QT_QPA_PLATFORMTHEME = "qt6ct";
      };
    };
}
