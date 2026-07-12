# Pointer cursor theme package. Selection and wiring are DMS-owned (its
# cursor settings write ~/.config/hypr/dms/cursor.lua — required by the
# Hyprland config, see hyprland.mod.nix — set XCURSOR_THEME for launched
# apps, and run hyprctl setcursor); this module only installs a theme into
# the profile so DMS's theme scanner (share/icons) has something to offer.
# home.pointerCursor is deliberately NOT used: it would generate competing
# GTK/x11/hyprcursor config.
{
  flake.homeModules.cursor =
    {
      lib,
      osConfig,
      pkgs,
      ...
    }:
    let
      inherit (lib.modules) mkIf;
    in
    {
      config = mkIf osConfig.isDesktop {
        home.packages = [ pkgs.bibata-cursors ];
      };
    };
}
