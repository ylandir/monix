# Matrix homeserver aspect — the family chat rail (and the assistant-bot
# rail: rooms are the UI, the budget bot is just another account). tuwunel
# (the Matrix-Foundation-backed conduwuit successor): a single Rust binary
# on RocksDB, right-sized for a three-account family server. Inert until a
# host sets `matrix.enable` (same pattern as actual.mod.nix).
#
# DELIBERATELY NOT A PUBLIC MATRIX NODE:
#   - allow_federation = false. This server speaks to no other homeserver;
#     rooms and users exist only here. That removes the entire federation
#     attack/abuse surface (and most of Matrix's operational confusion).
#   - Registration is token-gated, permanently: an account can only be
#     created with the registration token (agenix env secret). No open
#     signup, ever; the token is only handed out when adding a family
#     member or a bot.
#   - E2EE stays ALLOWED (clients may create encrypted rooms) but the
#     family rooms are intended unencrypted: transport is TLS into our own
#     hardware, and skipping E2EE removes device-verification friction and
#     keeps bot integration simple.
#
# ACCESS MODEL. Like actual.mod.nix: no public inbound port; tailnet
# reaches the listener directly (trusted-interface pattern) and the public
# hostname rides a dedicated Cloudflare Tunnel. NB: NO Cloudflare Access
# application on this hostname — Matrix clients speak the client-server
# API and cannot traverse an Access SSO wall; authentication is Matrix's
# own password login plus the token-gated registration above.
#
# THREAT MODEL / EGRESS. A Rust server parsing untrusted client input;
# upstream ships a tight sandbox (DynamicUser, strict FS, syscall filter,
# MemoryDenyWriteExecute) and we add the services.slice + the house
# anti-pivot fence. Egress must include the PUBLIC internet — federation
# is off, but phone notifications require the homeserver to call each
# client's push gateway (Element's sygnal at matrix.org); block that and
# mobile push silently dies. So this is the minecraft.mod.nix fence shape
# (public allowed; loopback pinholes, LAN, and fleet bridge denied), not
# the total-deny Actual shape.
#
# DATA. /var/lib/tuwunel (RocksDB), service-private. Chat history for the
# family — include it in the off-host backup design alongside
# /var/lib/actual and the Minecraft world.
{
  flake.nixosModules.matrix =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      inherit (lib.meta) getExe;
      inherit (lib.modules) mkIf;
      inherit (lib.options) mkEnableOption mkOption;
      inherit (lib) types;

      cfg = config.matrix;
    in
    {
      options.matrix = {
        enable = mkEnableOption "the family tuwunel Matrix homeserver (federation off, token-gated registration)";

        serverName = mkOption {
          type = types.str;
          example = "chat.example.com";
          description = ''
            The Matrix server_name — the domain in every user id
            (@max:<serverName>) AND the hostname clients type at login, so
            it must equal the public hostname served by the tunnel. Baked
            into the database on first start; changing it later means
            starting over.
          '';
        };

        port = mkOption {
          type = types.port;
          default = 6167;
          description = ''
            Client-API listen port (tuwunel's default). The Cloudflare
            public hostname must target this port.
          '';
        };

        registrationTokenEnvFile = mkOption {
          type = types.path;
          description = ''
            agenix-managed environment file containing
            TUWUNEL_REGISTRATION_TOKEN=<token> — the only way to create an
            account on this server. Rotate by re-encrypting the secret.
          '';
        };

        tunnelTokenFile = mkOption {
          type = types.nullOr types.path;
          default = null;
          description = ''
            Cloudflare Tunnel connector token for the chat hostname; null =
            tailnet-only. Its own tunnel (independent of the cockpit's and
            Actual's) so chat exposure is separately revocable. Hostname ->
            http://127.0.0.1:<port> mapping is dashboard-side; do NOT put a
            Cloudflare Access app on this hostname (see header).
          '';
        };
      };

      config = mkIf cfg.enable {
        services.matrix-tuwunel = {
          enable = true;
          environmentFile = cfg.registrationTokenEnvFile;
          settings.global = {
            server_name = cfg.serverName;
            port = [ cfg.port ];
            # Bind everywhere; reachability is the firewall's job (the fw0
            # pattern): zero public inbound ports, tailscale0 trusted,
            # loopback serves cloudflared.
            address = [
              "0.0.0.0"
              "::"
            ];
            # The three load-bearing policy switches (see header).
            allow_federation = false;
            allow_registration = true; # token-gated via the env secret
            allow_encryption = true;
            # tuwunel's default appends "💕" to every new account's display
            # name (uwu heritage; key verified in the 1.8.0 binary).
            # Existing accounts keep whatever name they have.
            new_user_displayname_suffix = "";
            # Federation is off; don't name notary key servers at all.
            trusted_servers = [ ];
            # (URL previews — an SSRF-shaped feature — are OFF by tuwunel
            # default; not stated explicitly because tuwunel rejects
            # configs with unrecognized keys and the exact key name isn't
            # verifiable from the stripped binary.)
          };
        };

        systemd.services.tuwunel.serviceConfig = {
          # Count chat against the general services fence.
          Slice = "services.slice";

          # Anti-pivot egress fence, minecraft shape: the public internet
          # stays reachable (push gateways — notifications die without it)
          # but the LAN and the fleet bridge do not. Unlike minecraft,
          # LOOPBACK IS ALLOWED: cloudflared delivers every public client
          # over 127.0.0.1, and systemd's IP filter can't distinguish that
          # inbound hop from outbound loopback use — the same trade
          # actual.mod.nix makes. systemd checks Allow before Deny;
          # unmatched = allowed (public).
          IPAddressAllow = [
            "127.0.0.0/8" # the cloudflared hop (and resolved's DNS stub)
            "::1"
            "100.64.0.0/10" # tailnet clients (CGNAT range)
          ];
          IPAddressDeny = [
            "10.0.0.0/8" # RFC1918 — incl. the agent-fleet bridge
            "172.16.0.0/12" # RFC1918
            "192.168.0.0/16" # RFC1918 — home LAN
            "169.254.0.0/16" # link-local
            "fc00::/7" # IPv6 ULA
            "fe80::/10" # IPv6 link-local
          ];
        };

        # Public web ingress: dedicated cloudflared connector (cf.
        # actual.mod.nix). Dials out to Cloudflare's edge; no inbound port.
        systemd.services.matrix-tunnel = mkIf (cfg.tunnelTokenFile != null) {
          description = "Cloudflare Tunnel for the Matrix homeserver";
          wantedBy = [ "multi-user.target" ];
          partOf = [ "tuwunel.service" ];
          wants = [
            "network-online.target"
            "tuwunel.service"
          ];
          after = [
            "network-online.target"
            "tuwunel.service"
          ];
          serviceConfig = {
            DynamicUser = true;
            LoadCredential = [ "token:${cfg.tunnelTokenFile}" ];
            ExecStart = "${getExe pkgs.cloudflared} tunnel --no-autoupdate run --token-file %d/token";
            Restart = "always";
            RestartSec = 5;
          };
          environment = {
            TUNNEL_TRANSPORT_PROTOCOL = "http2";
          };
        };
      };
    };
}
