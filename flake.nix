{
  description = "NixOS configuration (Dendritic, single-repo, modular)";

  nixConfig = {
    extra-substituters = [
      "https://nix-community.cachix.org"
    ];
    extra-trusted-public-keys = [
      "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
    ];
  };

  inputs.nixpkgs = {
    url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  inputs.nixos-hardware = {
    url = "github:NixOS/nixos-hardware/master";
  };

  inputs.flake-parts = {
    url = "github:hercules-ci/flake-parts";
    inputs.nixpkgs-lib.follows = "nixpkgs";
  };

  inputs.home-manager = {
    url = "github:nix-community/home-manager";
    inputs.nixpkgs.follows = "nixpkgs";
  };

  inputs.agenix = {
    url = "github:ryantm/agenix";
    inputs.nixpkgs.follows = "nixpkgs";
    inputs.home-manager.follows = "home-manager";
    inputs.darwin.follows = "";
  };

  # master, not stable: v1.4.6/stable predate the fixes for Hyprland 0.55's
  # Lua command socket (old-style `dispatch workspace N` strings are rejected,
  # breaking DMS workspace clicking; fixed on master ~2026-05).
  inputs.dank-material-shell = {
    url = "github:AvengeMedia/DankMaterialShell";
    inputs.nixpkgs.follows = "nixpkgs";
  };

  inputs.nix4nvchad = {
    url = "github:nix-community/nix4nvchad";
    inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    inputs:
    inputs.flake-parts.lib.mkFlake
      {
        inherit inputs;
        specialArgs.lib = import ./lib inputs.nixpkgs.lib;
      }
      (
        { lib, ... }:
        {
          systems = [
            "x86_64-linux"
            "aarch64-linux"
          ];

          # The Dendritic Pattern: every `*.mod.nix` file in the tree is a
          # flake-parts module and is imported automatically. There is no
          # central list of modules to maintain.
          imports = lib.lists.filter (lib.strings.hasSuffix ".mod.nix") (
            lib.filesystem.listFilesRecursive ./.
          );
        }
      );
}
