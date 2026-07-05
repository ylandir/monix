# Declarative disk layouts (nix-community/disko). Each host declares its
# layout under `disko.devices` in its host module; disko generates the
# `fileSystems`/LUKS mount config from it (replacing the old generated
# hardware-configuration.nix stanzas) and can format a blank disk to match:
#
#   nix run github:nix-community/disko -- --mode disko --flake .#<host>
#   nixos-install --flake .#<host>
#
# `nixos-rebuild switch` never formats — formatting only happens via the
# explicit disko command above.
{ inputs, ... }:
{
  flake.nixosModules.disko = inputs.disko.nixosModules.disko;
}
