# remy aspect — the family's household chat bot (see remy/bot.py). One
# Python service, two Matrix rooms, room-scoped skills:
#
#   - "Household" (created by the bot on first start, family invited):
#     tasks with due dates and named lists in plain language, a morning
#     plan (07:00) and evening report (19:00) with week-ahead sections,
#     folding in the family's Migadu calendar.
#   - "Budget" (pre-existing): the complete budgetbot skill set against
#     the same ledger at /var/lib/budgetbot/budget.db — remy ABSORBED
#     budgetbot 2026-07-13 (its module is gone; the ledger, its git
#     history, and the room stayed put).
#
# Deliberately NOT a general agent (budgetbot's constraint, upheld): chat
# text is untrusted input that only ever classifies into a fixed intent
# schema — no path to shell, SQL text, or the fleet. Inert until a host
# sets `remy.enable`.
#
# FOUR UNITS, one shared identity (static user `remy`, because DynamicUser
# can't share /var/lib across units):
#   - remy-register (oneshot): bootstraps @remy from the homeserver's
#     registration token; idempotent (login-check first). Loopback.
#   - remy-adopt-budget-room (oneshot): logs in as the RETIRED budgetbot
#     account once and invites @remy into the Budget room, so the merge
#     needs no manual Element step. Loopback; harmless on re-runs.
#   - remy: the bot. EVERY dependency is loopback — tuwunel (:6167),
#     llama-swap (:8091), the SQLite files, calendar.json. Total egress
#     fence; it holds exactly one credential: its own Matrix account.
#   - remy-calendar-sync (timer, only if calendar creds are configured):
#     the ONLY unit with internet egress and the ONLY holder of the
#     CalDAV credentials. Pulls upcoming events to calendar.json for the
#     bot to read. LAN/tailnet/fleet ranges stay denied even here.
#
# DATA. /var/lib/remy/home.db (organizer) + /var/lib/budgetbot/budget.db
# (ledger, path unchanged from budgetbot). Both on the list for the
# pending off-host backup design (with tuwunel/actual).
{
  flake.nixosModules.remy =
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

      cfg = config.remy;

      python = pkgs.python3.withPackages (ps: [
        ps.matrix-nio
        ps.matplotlib
        ps.requests
      ]);

      calPython = pkgs.python3.withPackages (ps: [ ps.caldav ]);

      # Register the bot's account on the loopback tuwunel if it doesn't
      # exist yet: try a login with the configured password; on failure walk
      # the registration-token UIA flow. Idempotent, loud on real failures
      # (wrong password for an existing account, bad token).
      register = pkgs.writeShellApplication {
        name = "remy-register";
        runtimeInputs = [
          pkgs.curl
          pkgs.jq
        ];
        text = ''
          hs="http://127.0.0.1:${toString config.matrix.port}"
          localpart=''${MATRIX_USER#@}; localpart=''${localpart%%:*}
          mcurl() {
            curl -s --connect-timeout 5 --max-time 30 \
              -H "Content-Type: application/json" "$@"
          }

          login=$(mcurl -X POST "$hs/_matrix/client/v3/login" \
            -d "$(jq -n --arg u "$MATRIX_USER" --arg p "$MATRIX_PASSWORD" \
              '{type:"m.login.password",identifier:{type:"m.id.user",user:$u},password:$p}')")
          tok=$(jq -r '.access_token // empty' <<< "$login")
          if [ -n "$tok" ]; then
            mcurl -X POST -H "Authorization: Bearer $tok" \
              "$hs/_matrix/client/v3/logout" -d '{}' > /dev/null || true
            echo "account $MATRIX_USER exists"
            exit 0
          fi

          session=$(mcurl -X POST "$hs/_matrix/client/v3/register" -d '{}' \
            | jq -er .session)
          out=$(mcurl -X POST "$hs/_matrix/client/v3/register" \
            -d "$(jq -n --arg u "$localpart" --arg p "$MATRIX_PASSWORD" \
                  --arg t "$TUWUNEL_REGISTRATION_TOKEN" --arg s "$session" \
              '{username:$u, password:$p, inhibit_login:true,
                auth:{type:"m.login.registration_token", token:$t, session:$s}}')")
          if jq -e '.user_id // empty' <<< "$out" > /dev/null; then
            echo "registered $MATRIX_USER"
          else
            echo "registration failed: $out" >&2
            exit 1
          fi
        '';
      };

      # One-time room handover: as the old budgetbot account, invite remy
      # into the Budget room. Every step tolerates having already happened
      # (re-invite of a member 403s; that's fine — remy joins on invite or
      # at startup).
      adopt = pkgs.writeShellApplication {
        name = "remy-adopt-budget-room";
        runtimeInputs = [
          pkgs.curl
          pkgs.jq
        ];
        text = ''
          hs="http://127.0.0.1:${toString config.matrix.port}"
          room=$(jq -rn --arg r ${lib.escapeShellArg cfg.budgetRoomId} '$r|@uri')
          mcurl() {
            curl -s --connect-timeout 5 --max-time 30 \
              -H "Content-Type: application/json" "$@"
          }
          tok=$(mcurl -X POST "$hs/_matrix/client/v3/login" \
            -d "$(jq -n --arg u "$OLD_MATRIX_USER" --arg p "$OLD_MATRIX_PASSWORD" \
              '{type:"m.login.password",identifier:{type:"m.id.user",user:$u},password:$p}')" \
            | jq -er .access_token)
          mcurl -X POST -H "Authorization: Bearer $tok" \
            "$hs/_matrix/client/v3/rooms/$room/invite" \
            -d "$(jq -n --arg u "$MATRIX_USER" '{user_id:$u}')" || true
          mcurl -X POST -H "Authorization: Bearer $tok" \
            "$hs/_matrix/client/v3/logout" -d '{}' > /dev/null || true
        '';
      };

      # Hardening shared by all units (cf. the retired budgetbot.mod.nix;
      # the tenant-standard sandbox). Egress differs per unit, set below.
      sandbox = {
        User = "remy";
        Group = "remy";
        StateDirectory = "remy budgetbot";
        StateDirectoryMode = "0700";
        Slice = "services.slice";

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

      loopbackOnly = {
        IPAddressAllow = [
          "127.0.0.0/8"
          "::1"
        ];
        IPAddressDeny = "any";
      };
    in
    {
      options.remy = {
        enable = mkEnableOption "the family household chat bot";

        credentialsEnvFile = mkOption {
          type = types.path;
          description = ''
            agenix env file with MATRIX_USER=@bot:server and
            MATRIX_PASSWORD=... — the bot's own Matrix account, its only
            credential. The account is auto-registered on first start.
          '';
        };

        registrationEnvFile = mkOption {
          type = types.path;
          description = ''
            agenix env file with TUWUNEL_REGISTRATION_TOKEN=... (the
            homeserver's, see matrix.mod.nix) — used only by the oneshot
            account-registration unit, never by the bot itself.
          '';
        };

        budgetRoomId = mkOption {
          type = types.str;
          example = "!abcdef:chat.example.com";
          description = "The existing Budget room (budgetbot's old home).";
        };

        budgetbotEnvFile = mkOption {
          type = types.nullOr types.path;
          default = null;
          description = ''
            The RETIRED budgetbot account's agenix env file (MATRIX_USER/
            MATRIX_PASSWORD) — used once by the adopt oneshot to invite
            remy into the Budget room. null once the invite has happened
            and the secret is retired.
          '';
        };

        inviteUsers = mkOption {
          type = types.listOf types.str;
          default = [ ];
          example = [ "@dylan:chat.example.com" ];
          description = ''
            Users invited when the bot creates its Household room on first
            start. The first entry also gets admin power in the room.
          '';
        };

        roomName = mkOption {
          type = types.str;
          default = "Household";
          description = "Name of the room the bot creates on first start.";
        };

        model = mkOption {
          type = types.str;
          default = "qwen3.6-35b-a3b";
          description = ''
            inference.models catalog id used for message parsing. The fast
            default model: classifying "we need X by friday" into JSON is
            squarely inside its weight class and keeps replies snappy.
          '';
        };

        morningTime = mkOption {
          type = types.str;
          default = "07:00";
          description = "Local HH:MM for the morning plan post.";
        };

        eveningTime = mkOption {
          type = types.str;
          default = "19:00";
          description = "Local HH:MM for the evening report post.";
        };

        calendar.credentialsFile = mkOption {
          type = types.nullOr types.path;
          default = null;
          description = ''
            agenix JSON file listing CalDAV accounts to fold into the
            daily posts: [{"name":..., "url":..., "username":...,
            "password":...}, ...]. null = no calendar section.
          '';
        };

        calendar.daysAhead = mkOption {
          type = types.ints.positive;
          default = 30;
          description = "How far ahead the calendar sync fetches events.";
        };
      };

      config = mkIf cfg.enable {
        assertions = [
          {
            assertion = config.matrix.enable && config.inference.enable;
            message = "remy needs the matrix homeserver and local inference aspects on this host";
          }
        ];

        users.users.remy = {
          isSystemUser = true;
          group = "remy";
        };
        users.groups.remy = { };

        systemd.services.remy-register = {
          description = "remy Matrix account bootstrap";
          wantedBy = [ "multi-user.target" ];
          wants = [ "tuwunel.service" ];
          after = [ "tuwunel.service" ];
          serviceConfig = sandbox // loopbackOnly // {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = getExe register;
            EnvironmentFile = [
              cfg.credentialsEnvFile
              cfg.registrationEnvFile
            ];
          };
        };

        systemd.services.remy-adopt-budget-room = mkIf (cfg.budgetbotEnvFile != null) {
          description = "invite remy into the Budget room as old budgetbot";
          wantedBy = [ "multi-user.target" ];
          wants = [ "remy-register.service" ];
          after = [
            "tuwunel.service"
            "remy-register.service"
          ];
          # Both env files use the same MATRIX_* names, so the old
          # account's file arrives as a systemd credential and is read
          # into OLD_* here instead of clobbering remy's own vars.
          script = ''
            f="$CREDENTIALS_DIRECTORY/budgetbot-env"
            OLD_MATRIX_USER=$(grep '^MATRIX_USER=' "$f" | cut -d= -f2-)
            OLD_MATRIX_PASSWORD=$(grep '^MATRIX_PASSWORD=' "$f" | cut -d= -f2-)
            export OLD_MATRIX_USER OLD_MATRIX_PASSWORD
            exec ${getExe adopt}
          '';
          serviceConfig = sandbox // loopbackOnly // {
            Type = "oneshot";
            RemainAfterExit = true;
            # remy's own env gives MATRIX_USER (the invitee); the old
            # account's file arrives as a systemd credential so its
            # MATRIX_* names can't collide with remy's.
            EnvironmentFile = cfg.credentialsEnvFile;
            LoadCredential = "budgetbot-env:${cfg.budgetbotEnvFile}";
          };
        };

        systemd.services.remy = {
          description = "family household chat bot";
          wantedBy = [ "multi-user.target" ];
          # The organizer's safety net: every mutation commits a SQL dump
          # to a git repo in the state dir (see git_snapshot in bot.py).
          path = [ pkgs.git ];
          wants = [
            "tuwunel.service"
            "remy-register.service"
          ];
          after = [
            "tuwunel.service"
            "remy-register.service"
            "remy-adopt-budget-room.service"
            "llama-swap.service"
          ];
          environment = {
            BOT_HS_URL = "http://127.0.0.1:${toString config.matrix.port}";
            BOT_INVITE_USERS = lib.concatStringsSep "," cfg.inviteUsers;
            BOT_ROOM_NAME = cfg.roomName;
            BOT_BUDGET_ROOM_ID = cfg.budgetRoomId;
            LLM_URL = "http://127.0.0.1:${toString config.inference.port}/v1/chat/completions";
            LLM_MODEL = cfg.model;
            BOT_DB = "/var/lib/remy/home.db";
            BOT_BUDGET_DB = "/var/lib/budgetbot/budget.db";
            BOT_CALENDAR_JSON = "/var/lib/remy/calendar.json";
            BOT_MORNING = cfg.morningTime;
            BOT_EVENING = cfg.eveningTime;
            BOT_TZ = config.time.timeZone;
            # matplotlib wants a writable config dir; PrivateTmp provides one.
            MPLCONFIGDIR = "/tmp/mpl";
          };
          serviceConfig = sandbox // loopbackOnly // {
            ExecStart = "${python}/bin/python ${./remy/bot.py}";
            EnvironmentFile = cfg.credentialsEnvFile;
            Restart = "always";
            RestartSec = 10;
          };
        };

        systemd.services.remy-calendar-sync = mkIf (cfg.calendar.credentialsFile != null) {
          description = "remy CalDAV calendar sync";
          environment = {
            REMY_CALDAV_CONFIG = cfg.calendar.credentialsFile;
            BOT_CALENDAR_JSON = "/var/lib/remy/calendar.json";
            REMY_CAL_DAYS = toString cfg.calendar.daysAhead;
          };
          serviceConfig = sandbox // {
            Type = "oneshot";
            ExecStart = "${calPython}/bin/python ${./remy/calsync.py}";
            # The one remy unit allowed out: HTTPS to the CalDAV host
            # (plus loopback for the resolver stub). Private, link-local,
            # tailnet, and fleet ranges stay denied — egress to the
            # internet only, never inward.
            IPAddressAllow = [
              "127.0.0.0/8"
              "::1"
            ];
            IPAddressDeny = [
              "link-local"
              "multicast"
              "10.0.0.0/8"
              "172.16.0.0/12"
              "192.168.0.0/16"
              "100.64.0.0/10"
              "fc00::/7"
              "fe80::/10"
            ];
          };
        };

        systemd.timers.remy-calendar-sync = mkIf (cfg.calendar.credentialsFile != null) {
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnBootSec = "5min";
            OnUnitActiveSec = "30min";
          };
        };
      };
    };
}
