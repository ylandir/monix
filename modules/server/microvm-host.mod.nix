# Agent-fleet microVM host. See docs/agent-fleet.md. Provides:
#   - the microvm.nix host runner (microvm@<name> units, virtiofsd, state dir);
#   - a HOST-ONLY bridge `br-agents` (10.100.0.1/24) with no NAT, no routing,
#     no DNS for guests — guests can reach nothing except the proxy below;
#   - `squid` as the SOLE egress path, a CONNECT allowlist that also produces
#     the egress audit log.
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
        ".openai.com" # Codex: OpenAI API + auth
        ".chatgpt.com" # Codex: ChatGPT-subscription backend/auth
        ".openrouter.ai" # opencode: OpenRouter API (any-model dispatch)
        ".models.dev" # opencode: provider/model registry it fetches at startup
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

        # Pre-own each worker's state dir as microvm:kvm. microvm.nix's
        # install-microvm runs as root and chowns each dir itself, but when a
        # BATCH of new workers installs at once and an install is interrupted
        # before its chown, the dir is left root-owned — then the microvm-user
        # `microvm-set-booted` step fails with EACCES and aborts the whole
        # activation (this is what broke the jump 2->12). A tmpfiles `d` rule
        # sets AND repairs the ownership deterministically, and it runs early in
        # activation (before the microvm units), so a large pool activates
        # cleanly and any previously root-owned dirs get fixed on the next switch.
        systemd.tmpfiles.rules = map (
          w: "d ${config.microvm.stateDir}/${w.name} 0755 microvm kvm -"
        ) cfg.workers;

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
          # Isolated ports cannot forward to other isolated ports at L2, but
          # can still deliver to the bridge master (the host). This drops
          # guest↔guest traffic while leaving guest→host:3128 (squid) intact.
          bridgeConfig.Isolated = true;
        };

        # EGRESS FIREWALL — from the bridge, guests may reach ONLY squid, plus
        # (when the host serves local inference) the llama-swap endpoint: a
        # deliberate pinhole so drones can call the ship's own models. That
        # service is the second host process parsing untrusted guest bytes
        # (squid is the first) and is sandboxed accordingly (inference.mod.nix).
        # br-agents is deliberately NOT a trusted interface, so the default
        # DROP handles everything else (incl. DNS/53 and the host's sshd). No
        # IP forwarding is enabled anywhere, so even this is belt-and-braces:
        # guests have no route off the bridge regardless.
        networking.firewall.interfaces.${bridge}.allowedTCPPorts = [
          3128
        ]
        ++ lib.lists.optionals config.inference.enable [ config.inference.port ];

        # SQUID — the single audited egress point. Bound to the bridge IP only.
        services.squid = {
          enable = true;
          configText = ''
            http_port ${hostAddr}:3128
            pid_filename /run/squid/squid.pid

            # Run as the squid user (owns /var/log/squid + /var/cache/squid);
            # without this squid drops to 'nobody' and can't write its logs.
            cache_effective_user squid

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

            # THIS is the egress audit trail: one line per request.
            access_log stdio:/var/log/squid/access.log
            cache_log stdio:/var/log/squid/cache.log
            coredump_dir /var/cache/squid
          '';
        };
        # HARDENING — squid is the ONE host process that parses bytes from the
        # untrusted guests, i.e. the single crack in the otherwise-clean KVM
        # boundary. Sandbox it so an exploited squid lands in an empty room:
        # read-only filesystem (logs/cache/pidfile excepted), no home dirs, no
        # new privileges, and only the capabilities/syscalls it needs to drop
        # from root to the squid user at startup (@setuid/@chown).
        systemd.services.squid.serviceConfig = {
          Slice = "agents.slice";

          NoNewPrivileges = true;
          ProtectSystem = "strict";
          ProtectHome = true;
          PrivateTmp = true;
          # ProtectSystem=strict leaves /run read-only, so the pidfile moves
          # into a RuntimeDirectory (the upstream module points PIDFile at
          # /run/squid.pid — realign it).
          RuntimeDirectory = "squid";
          PIDFile = lib.mkForce "/run/squid/squid.pid";
          ReadWritePaths = [
            "/var/log/squid"
            "/var/cache/squid"
          ];
          ProtectKernelTunables = true;
          ProtectKernelModules = true;
          ProtectKernelLogs = true;
          ProtectControlGroups = true;
          ProtectClock = true;
          ProtectHostname = true;
          ProtectProc = "invisible";
          RestrictAddressFamilies = [
            "AF_INET"
            "AF_INET6"
            "AF_UNIX"
            "AF_NETLINK"
          ];
          RestrictNamespaces = true;
          RestrictRealtime = true;
          RestrictSUIDSGID = true;
          LockPersonality = true;
          MemoryDenyWriteExecute = true;
          SystemCallArchitectures = "native";
          SystemCallFilter = [
            "@system-service"
            "@setuid"
            "@chown"
          ];
          CapabilityBoundingSet = [
            "CAP_SETUID"
            "CAP_SETGID"
            "CAP_CHOWN"
            "CAP_DAC_OVERRIDE"
          ];
        };
        })
      ];
    };
}
