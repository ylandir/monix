{ inputs, ... }:
{
  flake.commonModules.nix =
    { config, pkgs, ... }:
    {
      nix.settings = {
        experimental-features = [
          "flakes"
          "nix-command"
        ];

        # Trusted Nix users are passwordless root-equivalent via the daemon, so
        # this is deliberately NOT the whole @wheel group — just root and this
        # host's primary user. Admin still works via sudo (root is always
        # trusted); only the blanket group grant is dropped.
        trusted-users = [
          "root"
          config.primaryUser
        ];

        substituters = [
          "https://cache.nixos.org"
          "https://nix-community.cachix.org"
        ];
        trusted-public-keys = [
          "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
          "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
        ];

        warn-dirty = false;
      };

      # Pin the registry and NIX_PATH to this flake's nixpkgs so `nix run`,
      # `nix shell` and legacy `<nixpkgs>` lookups all resolve consistently.
      nix.registry.nixpkgs.flake = inputs.nixpkgs;
      nix.nixPath = [ "nixpkgs=${inputs.nixpkgs}" ];

      nix.channel.enable = false;

      # Scheduled optimisation; the per-write `auto-optimise-store` setting
      # slows every build and is discouraged upstream.
      nix.optimise.automatic = true;

      nix.gc = {
        automatic = true;
        dates = "weekly";
        options = "--delete-older-than 90d";
      };

      nixpkgs.config.allowUnfree = true;

      environment.systemPackages = [
        pkgs.nh
        pkgs.nix-output-monitor
      ];
    };
}
