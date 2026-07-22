# curtisbot aspect — Curtis, the work-Discord bot (see ./bot.py).
#
# WORK, not household: self-contained in this folder so it can
# be removed or moved to another machine's config wholesale — delete these
# two paths plus the enable/secret lines in hosts/fw0 and it's gone.
#
# Slash commands for the shop's two running lists: wholesale orders
# (/wholesale form -> order lines, /orders) and staff requests
# (/request form, /requests), both checked off via per-row buttons.
# Rows are never deleted — checking off stamps done_at/done_by and drops
# the row from the default views.
#
# One long-running unit. Egress is internet-only (Discord gateway/API) plus
# loopback for the resolver; LAN/tailnet/fleet ranges stay denied — the
# newsbot/remy-calendar-sync fence shape. The only credential is the bot
# token, supplied as an agenix env file (DISCORD_TOKEN=...); it is read from
# the environment and never written to disk or logs.
#
# DATA. /var/lib/curtisbot/bot.db (orders + requests, SQLite) — add
# to the list for the pending off-host backup design.
{
  flake.nixosModules.curtisbot =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      inherit (lib.modules) mkIf;
      inherit (lib.options) mkEnableOption mkOption;
      inherit (lib) types;

      cfg = config.curtisbot;
      networkFences = import ../../../lib/network-fences.nix;

      python = pkgs.python3.withPackages (ps: [ ps.discordpy ]);
    in
    {
      options.curtisbot = {
        enable = mkEnableOption "Curtis work-Discord orders/requests bot";

        credentialsEnvFile = mkOption {
          type = types.path;
          description = ''
            agenix env file with DISCORD_TOKEN=... — the bot token from the
            Discord developer portal.
          '';
        };

        guildId = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = ''
            Discord guild (server) id to sync slash commands to. Set it for
            instant command availability in that one server; null syncs
            globally, which Discord can take up to an hour to propagate.
          '';
        };
      };

      config = mkIf cfg.enable {
        users.users.curtisbot = {
          isSystemUser = true;
          group = "curtisbot";
        };
        users.groups.curtisbot = { };

        systemd.services.curtisbot = {
          description = "Curtis work-Discord orders/requests bot";
          wantedBy = [ "multi-user.target" ];
          wants = [ "network-online.target" ];
          after = [ "network-online.target" ];
          environment = {
            CURTISBOT_DB = "/var/lib/curtisbot/bot.db";
          } // lib.optionalAttrs (cfg.guildId != null) {
            DISCORD_GUILD_ID = cfg.guildId;
          };
          serviceConfig = {
            ExecStart = "${python}/bin/python ${./bot.py}";
            EnvironmentFile = cfg.credentialsEnvFile;
            Restart = "always";
            RestartSec = 10;

            User = "curtisbot";
            Group = "curtisbot";
            StateDirectory = "curtisbot";
            StateDirectoryMode = "0700";
            Slice = "services.slice";

            # Internet + loopback; LAN/tailnet/fleet stay denied.
            IPAddressAllow = [
              "127.0.0.0/8"
              "::1"
            ];
            IPAddressDeny = networkFences.internetOnlyDeny;

            CapabilityBoundingSet = "";
            LockPersonality = true;
            NoNewPrivileges = true;
            PrivateDevices = true;
            PrivateTmp = true;
            PrivateUsers = true;
            ProcSubset = "pid";
            ProtectClock = true;
            ProtectControlGroups = true;
            ProtectHome = true;
            ProtectHostname = true;
            ProtectKernelLogs = true;
            ProtectKernelModules = true;
            ProtectKernelTunables = true;
            ProtectProc = "invisible";
            ProtectSystem = "strict";
            RestrictAddressFamilies = [
              "AF_INET"
              "AF_INET6"
            ];
            RestrictNamespaces = true;
            RestrictRealtime = true;
            RestrictSUIDSGID = true;
            SystemCallArchitectures = "native";
            SystemCallFilter = [ "@system-service" ];
            SystemCallErrorNumber = "EPERM";
            UMask = "0077";
          };
        };
      };
    };
}
