# Config-less packages, grouped into functional bundles (ncc's pattern). Tools
# that carry configuration have their own concern files; Nix-workflow tools
# (nh, nix-output-monitor) live in nix.mod.nix; fonts in fonts.mod.nix.
{
  # The CLI baseline: essential system tools. System-scoped, universal: available to root and to
  # every user on both host classes. git is here (not only in the home git
  # concern) because managing and rebuilding this flake repo requires it in
  # root's PATH.
  flake.nixosModules.packages-cli =
    { pkgs, ... }:
    {
      environment.variables.EDITOR = "nvim";

      environment.systemPackages = [
        pkgs.curl
        pkgs.dig
        pkgs.eza
        pkgs.fd
        pkgs.fzf
        pkgs.git
        pkgs.gnumake
        pkgs.helix
        pkgs.htop
        pkgs.ipcalc
        pkgs.less
        pkgs.lf
        pkgs.libnotify
        pkgs.neovim
        pkgs.nushell
        pkgs.p7zip
        pkgs.ripgrep
        pkgs.rsync
        pkgs.tmux
        pkgs.traceroute
        pkgs.tree
        pkgs.unzip
        pkgs.vim
        pkgs.wget
        pkgs.xz
        pkgs.zip
        pkgs.zstd
      ];
    };

  # The Hyprland session's loose utilities. hyprshot wraps its own grim/slurp dependencies.
  flake.homeModules.packages-desktop =
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
          pkgs.kdePackages.dolphin
          pkgs.hyprpicker
          pkgs.hyprshot
          pkgs.hugo
          pkgs.pamixer
          pkgs.pavucontrol
          pkgs.playerctl
          pkgs.wl-clip-persist
          pkgs.wl-clipboard
          pkgs.wlr-randr
        ];
      };
    };

  # Desktop applications wired into the Hyprland quick-app bindings. The
  # source's wider personal list (second/third browsers, alacritty, libreoffice,
  # gamescope, ollama, prismlauncher, ...) is deliberately not ported; re-add
  # per host or here as needed.
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
          pkgs.keepassxc
        ];
      };
    };
}
