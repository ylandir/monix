# Agent-fleet microVM host (Phase 2, step 1 — host infrastructure only, no
# guest yet). See docs/phase2-agent-vm.md. Provides:
#   - the microvm.nix host runner (microvm@<name> units, virtiofsd, state dir);
#   - a HOST-ONLY bridge `br-agents` (10.100.0.1/24) with no NAT, no routing,
#     no DNS for guests — guests can reach nothing except the proxy below;
#   - `squid` as the SOLE egress path, a CONNECT allowlist that also produces
#     the egress audit log (plan §9).
#
# Egress is structural, not a rule to get right: guests have no default route
# and no DNS, so the only way out is CONNECT through squid on the bridge IP,
# which enforces the domain allowlist. Default-deny by construction.
#
# NETWORKING SAFETY: this touches ONLY `br-agents` and the `vm-*` taps via
# systemd-networkd. The host uplinks stay on their existing dhcpcd DHCP —
# `dhcpcd.denyInterfaces` fences the bridge/taps off so the two managers never
# fight. A misconfigured bridge cannot take down the uplinks (or your SSH).
{ inputs, ... }:
{
  flake.nixosModules.microvm-host =
    {
      config,
      lib,
      ...
    }:
    let
      inherit (lib.lists) singleton;
      inherit (lib.modules) mkIf mkMerge;
      inherit (lib.options) mkEnableOption;
      inherit (lib.strings) concatStringsSep;

      cfg = config.agentFleet;
      bridge = "br-agents";
      hostAddr = "10.100.0.1";

      # The egress allowlist — the ONLY destinations a guest can reach. Keep it
      # minimal; every entry is a potential exfiltration channel. Widen only by
      # reviewed commit. A leading-dot dstdomain matches the domain AND all
      # subdomains, so the dotted forms below already cover api.anthropic.com,
      # codeload/objects.github*.com, cache/channels.nixos.org, etc. — don't
      # also list the specific hosts (squid rejects the redundancy).
      allowedDomains = [
        ".anthropic.com" # Claude API + Claude Code auth/telemetry
        ".github.com" # git over https, codeload
        ".githubusercontent.com" # raw/objects
        ".nixos.org" # nix binary cache, channels, releases
      ];
    in
    {
      imports = singleton inputs.microvm.nixosModules.host;

      options.agentFleet.enable = mkEnableOption "the agent-fleet microVM host role";

      config = mkMerge [
        # The microvm.nix host runner defaults to ON once its module is
        # imported, and this aspect is imported on every host — so gate it
        # explicitly (unconditionally) to keep it OFF on desktops/non-fleet
        # servers.
        { microvm.host.enable = cfg.enable; }

        (mkIf cfg.enable {
        # Guest state (scratch images, overlays) on the dedicated @agents
        # dataset, not the root subvol.
        microvm.stateDir = "/var/lib/agents/microvms";

        # NETWORKING — full systemd-networkd (NOT mixed with scripted dhcpcd,
        # which NixOS warns can drop networking). networkd becomes authoritative
        # for all interfaces, so the onboard uplink is configured explicitly
        # (DHCP, unchanged behaviour); the host-only bridge and VM taps are the
        # new managed links.
        networking.useNetworkd = true;

        # Onboard uplink (enp*) stays on DHCP. tailscale0 is left to tailscaled
        # (no match here); lo is networkd's own default.
        systemd.network.networks."10-uplink" = {
          matchConfig.Name = "en*";
          networkConfig.DHCP = "yes";
          linkConfig.RequiredForOnline = "routable";
        };

        # HOST-ONLY BRIDGE — no uplink port is ever enslaved, so it cannot route
        # anywhere. Guests attach via vm-* taps (auto-enslaved by the match
        # below). RequiredForOnline=no so a carrier-less internal bridge never
        # blocks boot.
        systemd.network.netdevs."30-${bridge}".netdevConfig = {
          Name = bridge;
          Kind = "bridge";
        };

        systemd.network.networks."30-${bridge}" = {
          matchConfig.Name = bridge;
          address = singleton "${hostAddr}/24";
          networkConfig.ConfigureWithoutCarrier = true;
          linkConfig.RequiredForOnline = "no";
        };

        systemd.network.networks."31-agent-taps" = {
          matchConfig.Name = "vm-*";
          networkConfig.Bridge = bridge;
          linkConfig.RequiredForOnline = "no";
        };

        # EGRESS FIREWALL — from the bridge, guests may reach ONLY squid.
        # br-agents is deliberately NOT a trusted interface, so the default
        # DROP handles everything else (incl. DNS/53 and the host's sshd). No
        # IP forwarding is enabled anywhere, so even this is belt-and-braces:
        # guests have no route off the bridge regardless.
        networking.firewall.interfaces.${bridge}.allowedTCPPorts = [ 3128 ];

        # SQUID — the single audited egress point. Bound to the bridge IP only.
        services.squid = {
          enable = true;
          configText = ''
            http_port ${hostAddr}:3128
            pid_filename /run/squid.pid

            acl allowed_domains dstdomain ${concatStringsSep " " allowedDomains}
            acl SSL_ports port 443
            acl Safe_ports port 80 443
            acl CONNECT method CONNECT

            # Order matters: deny unsafe first, then allow only the allowlist.
            http_access deny !Safe_ports
            http_access deny CONNECT !SSL_ports
            http_access allow allowed_domains
            http_access deny all

            # Proxy, not cache.
            cache deny all

            # THIS is the egress audit trail (plan §9): one line per request.
            access_log stdio:/var/log/squid/access.log
            cache_log stdio:/var/log/squid/cache.log
            coredump_dir /var/cache/squid
          '';
        };
        systemd.services.squid.serviceConfig.Slice = "agents.slice";
        })
      ];
    };
}
