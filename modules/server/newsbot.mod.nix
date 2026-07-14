# newsbot aspect — morning/evening news digests in a private Matrix room.
#
# A timer (07:00 + 19:00 local) runs HEADLESS CLAUDE (`claude -p`, bills
# the subscription per the 2026-07-12 finding) with web search to compile
# a cross-category digest from the repo-tracked prompt
# (newsbot/prompt.md — the tuning knob; captain expects heavy iteration),
# then posts it to the "News" room as @newsbot. One-way for now: the bot
# never reads the room, so there is no chat-input attack surface at all —
# adding interactivity later is a separate permission decision.
#
# Unlike remy/budgetbot this NEEDS internet egress (api.anthropic.com;
# the web search itself runs server-side at Anthropic) — fenced like
# remy-calendar-sync: public allowed, loopback allowed (tuwunel post),
# LAN/tailnet/fleet denied. Credentials: its own Matrix account + the
# fleet's existing claude token (read via LoadCredential).
#
# Room bootstrap is self-serve (fleet-log-stream pattern): first run
# creates the room, invites the family, stamps the id in the state dir.
# Account bootstrap reuses remy's registration-token UIA walk.
{
  flake.nixosModules.newsbot =
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

      cfg = config.newsbot;

      # Same idempotent registration walk as remy-register (third user
      # would justify extracting a shared builder).
      register = pkgs.writeShellApplication {
        name = "newsbot-register";
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

      digest = pkgs.writeShellApplication {
        name = "news-digest";
        runtimeInputs = [
          pkgs.claude-code
          pkgs.curl
          pkgs.jq
          pkgs.coreutils
        ];
        text = ''
          hs="http://127.0.0.1:${toString config.matrix.port}"
          mcurl() {
            curl -s --connect-timeout 5 --max-time 60 \
              -H "Content-Type: application/json" "$@"
          }

          # ---- compile the digest (headless claude + server-side search)
          CLAUDE_CODE_OAUTH_TOKEN=$(cat "$CREDENTIALS_DIRECTORY/claude-token")
          export CLAUDE_CODE_OAUTH_TOKEN
          slot=morning; [ "$(date +%H)" -ge 12 ] && slot=evening
          text=$(claude -p \
            --model ${lib.escapeShellArg cfg.model} \
            --allowedTools "WebSearch" \
            "$(cat ${./newsbot/prompt.md})

          This is the $slot digest. Right now it is $(date '+%A %B %-d %Y, %H:%M %Z').")
          [ -n "$text" ] || { echo "empty digest from claude" >&2; exit 1; }
          header="📰 $(date '+%A %b %-d') — $slot digest"

          # ---- post it
          tok=$(mcurl -X POST "$hs/_matrix/client/v3/login" \
            -d "$(jq -n --arg u "$MATRIX_USER" --arg p "$MATRIX_PASSWORD" \
              '{type:"m.login.password",identifier:{type:"m.id.user",user:$u},password:$p}')" \
            | jq -er .access_token)

          # First run: create the room, invite the family, stamp the id.
          idfile=/var/lib/newsbot/room-id
          if [ ! -s "$idfile" ]; then
            mcurl -X POST -H "Authorization: Bearer $tok" \
              "$hs/_matrix/client/v3/createRoom" \
              -d "$(jq -n --arg n ${lib.escapeShellArg cfg.roomName} \
                    --argjson inv ${lib.escapeShellArg (builtins.toJSON cfg.inviteUsers)} \
                '{name:$n, preset:"private_chat", invite:$inv,
                  topic:"Morning and evening news digests."}')" \
              | jq -er .room_id > "$idfile"
          fi
          room=$(jq -rn --arg r "$(cat "$idfile")" '$r|@uri')

          mcurl -X PUT -H "Authorization: Bearer $tok" \
            "$hs/_matrix/client/v3/rooms/$room/send/m.room.message/$(date +%s%N)-$$" \
            -d "$(jq -n --arg b "$header

          $text" '{msgtype:"m.text", body:$b}')" > /dev/null

          mcurl -X POST -H "Authorization: Bearer $tok" \
            "$hs/_matrix/client/v3/logout" -d '{}' > /dev/null || true
        '';
      };

      sandbox = {
        User = "newsbot";
        Group = "newsbot";
        StateDirectory = "newsbot";
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
    in
    {
      options.newsbot = {
        enable = mkEnableOption "morning/evening news digests in a Matrix room";

        credentialsEnvFile = mkOption {
          type = types.path;
          description = ''
            agenix env file with MATRIX_USER=@bot:server and
            MATRIX_PASSWORD=... — the bot's own Matrix account
            (auto-registered on first start).
          '';
        };

        registrationEnvFile = mkOption {
          type = types.path;
          description = "TUWUNEL_REGISTRATION_TOKEN env file (see matrix.mod.nix).";
        };

        claudeTokenFile = mkOption {
          type = types.path;
          description = ''
            Raw CLAUDE_CODE_OAUTH_TOKEN file (the fleet's existing
            agent-claude-token secret) — headless claude compiles the
            digest on the subscription.
          '';
        };

        inviteUsers = mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = "Invited when the bot creates its room on first run.";
        };

        roomName = mkOption {
          type = types.str;
          default = "News";
          description = "Name of the room the bot creates on first run.";
        };

        model = mkOption {
          type = types.str;
          default = "sonnet";
          description = ''
            claude -p model for digest compilation. sonnet: current-events
            summarization with server-side search is comfortably inside
            its weight class; the scarce opus/fable capacity stays for
            judgment-dense cockpit work.
          '';
        };

        times = mkOption {
          type = types.listOf types.str;
          default = [
            "07:00"
            "19:00"
          ];
          description = "Local times (systemd OnCalendar HH:MM) to post digests.";
        };
      };

      config = mkIf cfg.enable {
        assertions = [
          {
            assertion = config.matrix.enable;
            message = "newsbot needs the matrix homeserver aspect on this host";
          }
        ];

        users.users.newsbot = {
          isSystemUser = true;
          group = "newsbot";
        };
        users.groups.newsbot = { };

        systemd.services.newsbot-register = {
          description = "news bot Matrix account bootstrap";
          wantedBy = [ "multi-user.target" ];
          wants = [ "tuwunel.service" ];
          after = [ "tuwunel.service" ];
          serviceConfig = sandbox // {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = getExe register;
            EnvironmentFile = [
              cfg.credentialsEnvFile
              cfg.registrationEnvFile
            ];
            IPAddressAllow = [
              "127.0.0.0/8"
              "::1"
            ];
            IPAddressDeny = "any";
          };
        };

        systemd.services.news-digest = {
          description = "compile and post the news digest";
          wants = [ "tuwunel.service" ];
          after = [
            "tuwunel.service"
            "newsbot-register.service"
            "network-online.target"
          ];
          environment = {
            # claude wants a writable HOME for its session state.
            HOME = "/var/lib/newsbot";
          };
          serviceConfig = sandbox // {
            Type = "oneshot";
            ExecStart = getExe digest;
            EnvironmentFile = cfg.credentialsEnvFile;
            LoadCredential = "claude-token:${cfg.claudeTokenFile}";
            # Search-heavy compilation can take a few minutes.
            TimeoutStartSec = "15min";
            # Internet + loopback; LAN/tailnet/fleet stay denied (the
            # remy-calendar-sync egress shape).
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

        systemd.timers.news-digest = {
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnCalendar = map (t: "*-*-* ${t}:00") cfg.times;
            # A digest missed while the ship was down still posts (late,
            # once) — same posture as remy's scheduled posts.
            Persistent = true;
          };
        };
      };
    };
}
