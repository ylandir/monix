# Cockpit: the user's primary interactive agent session lives on the host that
# enables this. Claude Code over tmux/SSH and opencode web are interchangeable
# frontends to the same captain's seat. It carries full user privileges
# (contrast with the locked-down fleet workers of agent-vm.mod.nix).
#
# The agent tooling itself (claude-code, codex, CLAUDE.md) comes from the
# existing home aspects in packages.mod.nix / claude.mod.nix, which gate on
# `isDesktop || cockpit.enable`.
{ inputs, ... }:
{
  flake.homeModules.cockpit =
    {
      config,
      lib,
      osConfig,
      ...
    }:
    let
      guide = import ../../lib/fleet-guide.nix;
      inherit (lib.modules) mkIf;
    in
    {
      config = mkIf osConfig.cockpit.enable {
        home.file."cockpit/AGENTS.md" = {
          force = true;
          text = guide.system + guide.pilot;
        };
        home.file."cockpit/CLAUDE.md" = {
          force = true;
          text = "@AGENTS.md\n";
        };

        # Vendor-neutral path for durable cockpit memory. Preserve the
        # existing storage location so historical memory remains available.
        home.file."cockpit/memory".source = config.lib.file.mkOutOfStoreSymlink (
          "/home/${osConfig.primaryUser}/.claude/projects/-home-max-cockpit/memory"
        );

        # /launch — Claude-specific shortcut for the vendor-neutral spoken
        # "launch the ship" pre-flight in AGENTS.md.
        home.file."cockpit/.claude/commands/launch.md" = {
          force = true;
          text = ''
            ---
            description: Pre-flight — orient in the cockpit and report ship status
            ---

            Run the pre-flight ("launch the ship") from AGENTS.md:

            1. Read `~/cockpit/memory/MEMORY.md` and open every
               memory relevant to active or open work.
            2. Run `sudo -n -u fleet-operator fleet health` and then `fleet status`
               (each standalone, never chained).
            3. Report in a few lines: ship status, drone-fleet health, the open backlog
               and loose ends, and anything time-sensitive. Then hold for a heading from
               the captain — don't start work unprompted.
          '';
        };
      };
    };

  flake.nixosModules.cockpit =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      inherit (lib.lists) singleton;
      inherit (lib.meta) getExe;
      inherit (lib.modules) mkIf;
      inherit (lib.options) mkEnableOption mkOption;
      inherit (lib) types;
    in
    {
      options.cockpit.enable = mkEnableOption "the persistent cockpit session role on this host";

      options.cockpit.webEnable = mkEnableOption "the opencode web cockpit seat";

      options.cockpit.webEnvFile = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          EnvironmentFile holding OPENCODE_SERVER_PASSWORD=<basic-auth pw>
          for the opencode web UI; null = no web UI. This is the app-local
          password layer. If the UI is exposed beyond the tailnet, put
          Cloudflare Access in front too: opencode web controls a shell-capable
          cockpit seat.
        '';
      };

      options.cockpit.webTunnelTokenFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = ''
          Cloudflare Tunnel connector token for exposing the opencode web
          cockpit at ai.su.is; null = no public tunnel. The public hostname
          and origin service are managed in Cloudflare Zero Trust.
        '';
      };

      config = mkIf config.cockpit.enable {
        assertions = [
          {
            assertion = config.cockpit.webTunnelTokenFile == null || config.cockpit.webEnable;
            message = "cockpit.webTunnelTokenFile requires cockpit.webEnable";
          }
        ];

        # tmux is the session's persistence layer; the binary is already
        # system-wide (packages-shell-utils), this adds the /etc config.
        programs.tmux.enable = true;
        programs.tmux.historyLimit = 50000;

        # The cockpit is where secrets get created/rotated (`agenix -e ...`
        # from the repo root) — fleet credentials in particular originate
        # here (`claude setup-token`, Codex's auth.json).
        environment.systemPackages = singleton inputs.agenix.packages.${pkgs.stdenv.hostPlatform.system}.default;

        # OPENCODE WEB — the cockpit from a browser: opencode's bundled
        # server + web UI, running AS the primary user (this is the human's
        # seat — it needs their auth.json, home, and full tooling, so it is
        # deliberately NOT filesystem-sandboxed like a tenant service). Binds
        # to loopback behind nginx; Cloudflare Tunnel is the public ingress
        # when enabled. nginx keeps ai.su.is stable on :4096.
        services.nginx = mkIf config.cockpit.webEnable {
          enable = true;
          recommendedProxySettings = true;
          virtualHosts."opencode-web-cockpit" = {
            listen = singleton {
              addr = "127.0.0.1";
              port = 4096;
            };
            locations."/" = {
              proxyPass = "http://127.0.0.1:4097";
              proxyWebsockets = true;
              extraConfig = ''
                proxy_buffering off;
              '';
            };
          };
        };

        systemd.services.opencode-web = mkIf config.cockpit.webEnable {
          description = "opencode web UI cockpit seat";
          wantedBy = [ "multi-user.target" ];
          wants = [ "network-online.target" ];
          after = [ "network-online.target" ];
          # Agents spawned from web sessions need the same tools a login
          # shell would have: system-wide packages plus the user's own
          # profile (where claude-code/codex/opencode themselves live).
          # NixOS privilege wrappers must precede the unwrapped packages in
          # the system profile; otherwise sudo finds its non-setuid binary.
          path = [
            "/run/wrappers"
            "/run/current-system/sw"
            "/etc/profiles/per-user/${config.primaryUser}"
          ];
          serviceConfig = {
            User = config.primaryUser;
            Group = "users";
            Slice = "cockpit.slice";
            EnvironmentFile = mkIf (config.cockpit.webEnvFile != null) config.cockpit.webEnvFile;
            WorkingDirectory = "/home/${config.primaryUser}/cockpit";
            ExecStart = "${getExe pkgs.opencode} web --hostname 127.0.0.1 --port 4097 --cors https://ai.su.is --print-logs";
            Restart = "always";
            RestartSec = 3;
          };
        };

        # The captain's seat legitimately runs builds and tools, but a remote
        # session still must not consume every byte or PID on the host.
        systemd.slices.cockpit.sliceConfig = mkIf config.cockpit.webEnable {
          MemoryHigh = "48G";
          MemoryMax = "64G";
          TasksMax = 8192;
        };

        systemd.services.opencode-web-tunnel = mkIf (config.cockpit.webTunnelTokenFile != null) {
          description = "Cloudflare Tunnel for opencode web";
          wantedBy = [ "multi-user.target" ];
          partOf = [
            "nginx.service"
            "opencode-web.service"
          ];
          wants = [
            "network-online.target"
            "nginx.service"
            "opencode-web.service"
          ];
          after = [
            "network-online.target"
            "nginx.service"
            "opencode-web.service"
          ];
          serviceConfig = {
            DynamicUser = true;
            LoadCredential = [ "token:${config.cockpit.webTunnelTokenFile}" ];
            ExecStart = "${getExe pkgs.cloudflared} tunnel --no-autoupdate run --token-file %d/token";
            Restart = "always";
            RestartSec = 5;
          };
          environment = {
            TUNNEL_TRANSPORT_PROTOCOL = "http2";
          };
        };

        # Cloudflare Access is configured outside Nix. Probe it without a
        # cookie so dashboard drift cannot silently turn this shell-capable
        # endpoint public again; a failed check remains visible in systemd and
        # `fleet health` until corrected.
        systemd.services.opencode-web-access-check = mkIf (config.cockpit.webTunnelTokenFile != null) {
          description = "Verify Cloudflare Access protects the opencode cockpit";
          wants = [ "network-online.target" ];
          after = [
            "network-online.target"
            "opencode-web-tunnel.service"
          ];
          path = [ pkgs.curl ];
          serviceConfig = {
            Type = "oneshot";
            DynamicUser = true;
            NoNewPrivileges = true;
            PrivateTmp = true;
            ProtectHome = true;
            ProtectSystem = "strict";
          };
          script = ''
            check() {
              result="$(curl --silent --show-error --max-time 20 --output /dev/null \
                --write-out '%{http_code} %{redirect_url}' "$1")"
              case "$result" in
                302\ https://*.cloudflareaccess.com/*) ;;
                *)
                  echo "Cloudflare Access check failed for $1: $result" >&2
                  exit 1
                  ;;
              esac
            }
            check https://ai.su.is/
            check https://ai.su.is/session
          '';
        };

        systemd.timers.opencode-web-access-check = mkIf (config.cockpit.webTunnelTokenFile != null) {
          description = "Periodically verify Cloudflare Access";
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnBootSec = "2m";
            OnUnitActiveSec = "5m";
            Unit = "opencode-web-access-check.service";
          };
        };
      };
    };
}
