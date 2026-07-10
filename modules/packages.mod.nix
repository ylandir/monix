# Config-less packages, grouped into functional bundles. Tools
# that carry configuration have their own concern files; Nix-workflow tools
# (nh, nix-output-monitor) live in nix.mod.nix; fonts in fonts.mod.nix.
#
# System-scoped bundles are universal: available to root and every user on
# both host classes. Home bundles gate themselves on isDesktop.
{
  flake.nixosModules.packages-editors =
    { pkgs, ... }:
    {
      environment.variables.EDITOR = "nvim";

      # neovim deliberately absent: NvChad's wrapper provides `nvim` per-user
      # (see editors.mod.nix) and collides with a plain install.
      environment.systemPackages = [
        pkgs.vim
      ];
    };

  # Interactive CLI quality-of-life. nushell is here (not only a host's login
  # shell setting) so the binary exists system-wide wherever a user picks it.
  flake.nixosModules.packages-shell-utils =
    { pkgs, ... }:
    {
      environment.systemPackages = [
        pkgs.eza
        pkgs.fd
        pkgs.fzf
        pkgs.htop
        pkgs.less
        pkgs.nushell
        pkgs.ripgrep
        pkgs.tmux
        pkgs.tree
      ];
    };

  flake.nixosModules.packages-network-tools =
    { pkgs, ... }:
    {
      environment.systemPackages = [
        pkgs.curl
        pkgs.dig
        pkgs.ipcalc
        pkgs.rsync
        pkgs.traceroute
        pkgs.wget
      ];
    };

  flake.nixosModules.packages-archives =
    { pkgs, ... }:
    {
      environment.systemPackages = [
        pkgs.p7zip
        pkgs.unzip
        pkgs.xz
        pkgs.zip
        pkgs.zstd
      ];
    };

  # git is here (not only in the home git concern) because managing and
  # rebuilding this flake repo requires it in root's PATH.
  flake.nixosModules.packages-dev-tools =
    { pkgs, ... }:
    {
      environment.systemPackages = [
        pkgs.git
        pkgs.gnumake
        pkgs.jujutsu
      ];
    };

  # The Hyprland session's loose utilities. hyprshot wraps its own grim/slurp
  # dependencies; libnotify provides notify-send for session scripts.
  flake.homeModules.packages-desktop-utils =
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
        home.packages = [
          pkgs.brightnessctl
          pkgs.cliphist
          pkgs.hyprpicker
          pkgs.hyprshot
          pkgs.libnotify
          pkgs.pamixer
          pkgs.pavucontrol
          pkgs.playerctl
          pkgs.wl-clip-persist
          pkgs.wl-clipboard
          pkgs.wlr-randr
        ];
      };
    };

  # Desktop applications wired into the Hyprland quick-app bindings.
  flake.homeModules.packages-apps =
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
        home.packages = [
          pkgs.brave
          pkgs.kdePackages.dolphin
          pkgs.keepassxc
          pkgs.libreoffice
          pkgs.obsidian
          pkgs.signal-desktop
        ];
      };
    };

  # Authoring/build tools for anywhere the user actually works: workstations
  # and the cockpit host (the server carrying the primary Claude session,
  # see cockpit.mod.nix).
  flake.homeModules.packages-dev-extras =
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
      config = mkIf (osConfig.isDesktop || osConfig.cockpit.enable) {
        home.packages = [
          pkgs.claude-code
          pkgs.codex
          pkgs.opencode
          pkgs.hugo
          # The codex Claude Code plugin's hooks invoke `node` directly.
          pkgs.nodejs
        ];
      };
    };
}
