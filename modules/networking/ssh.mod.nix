{
  flake.nixosModules.ssh =
    { config, lib, ... }:
    let
      inherit (lib.modules) mkDefault mkIf;
    in
    {
      services.openssh = {
        enable = true;

        # ZERO INBOUND on servers: sshd stays reachable over the tailnet only
        # (tailscale0 is a trusted interface, see tailscale.mod.nix); port 22
        # never opens on the public firewall. Desktops keep the default open
        # port for LAN access.
        openFirewall = mkIf (!config.isDesktop) (mkDefault false);

        settings = {
          PasswordAuthentication = mkDefault false;
          KbdInteractiveAuthentication = mkDefault false;
          PermitRootLogin = mkDefault "no";
        };
      };

      # Root deliberately has NO authorized keys: admin access is the primary
      # user + sudo; root logins are console-only. PermitRootLogin = "no"
      # forbids root SSH outright, so even a stray authorized key could not
      # enable it — belt and suspenders over the no-keys convention.
    };
}
