# budgetbot aspect — the family budget's chat interface (see
# budgetbot/bot.py). One Python service in a Matrix room: purchases typed
# in plain language are parsed by SHIP-LOCAL inference into its own SQLite
# ledger; it answers spending questions, posts charts, applies
# corrections, and nags when entries go stale. Deliberately NOT an
# Actual-Budget client and NOT a general agent: chat text is untrusted
# input that only ever classifies into a fixed intent schema — no path to
# shell, SQL text, or the fleet. Inert until a host sets
# `budgetbot.enable` (pattern: actual.mod.nix / matrix.mod.nix).
#
# EVERY dependency is loopback: tuwunel (:6167), llama-swap (:8091), and
# the SQLite file. So the egress fence is total — the bot can reach
# nothing but this machine, and nothing on the LAN/fleet/internet even if
# fully compromised. It holds exactly one credential: its own Matrix
# account.
#
# DATA. /var/lib/budgetbot/budget.db — the family ledger. Third entry for
# the pending off-host backup design (with /var/lib/tuwunel and
# /var/lib/actual).
{
  flake.nixosModules.budgetbot =
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

      cfg = config.budgetbot;

      python = pkgs.python3.withPackages (ps: [
        ps.matrix-nio
        ps.matplotlib
        ps.requests
      ]);
    in
    {
      options.budgetbot = {
        enable = mkEnableOption "the family budget chat bot";

        roomId = mkOption {
          type = types.str;
          example = "!abcdef:chat.example.com";
          description = "The Matrix room the bot lives in (it ignores every other room).";
        };

        credentialsEnvFile = mkOption {
          type = types.path;
          description = ''
            agenix env file with MATRIX_USER=@bot:server and
            MATRIX_PASSWORD=... — the bot's own Matrix account, its only
            credential.
          '';
        };

        model = mkOption {
          type = types.str;
          default = "qwen3.6-35b-a3b";
          description = ''
            inference.models catalog id used for message parsing. The fast
            default model, not the large one: parsing "costco 84.12" into
            JSON is squarely inside its weight class and keeps replies
            snappy.
          '';
        };
      };

      config = mkIf cfg.enable {
        assertions = [
          {
            assertion = config.matrix.enable && config.inference.enable;
            message = "budgetbot needs the matrix homeserver and local inference aspects on this host";
          }
        ];

        systemd.services.budgetbot = {
          description = "family budget chat bot";
          wantedBy = [ "multi-user.target" ];
          wants = [ "tuwunel.service" ];
          after = [
            "tuwunel.service"
            "llama-swap.service"
          ];
          environment = {
            BOT_HS_URL = "http://127.0.0.1:${toString config.matrix.port}";
            BOT_ROOM_ID = cfg.roomId;
            LLM_URL = "http://127.0.0.1:${toString config.inference.port}/v1/chat/completions";
            LLM_MODEL = cfg.model;
            BOT_DB = "/var/lib/budgetbot/budget.db";
            # matplotlib wants a writable config dir; PrivateTmp provides one.
            MPLCONFIGDIR = "/tmp/mpl";
          };
          serviceConfig = {
            ExecStart = "${python}/bin/python ${./budgetbot/bot.py}";
            EnvironmentFile = cfg.credentialsEnvFile;
            Restart = "always";
            RestartSec = 10;

            DynamicUser = true;
            StateDirectory = "budgetbot";
            StateDirectoryMode = "0700";
            Slice = "services.slice";

            # Standard tenant sandbox (cf. upstream actual/tuwunel units).
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

            # Total egress fence: everything the bot needs is loopback.
            IPAddressAllow = [
              "127.0.0.0/8"
              "::1"
            ];
            IPAddressDeny = "any";
          };
        };
      };
    };
}
