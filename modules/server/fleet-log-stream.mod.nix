# Fleet ops feed — streams the agent-fleet audit log into a Matrix room,
# line for line, no AI involved. A resident service tails
# /var/lib/agents/tasks/log (world-readable by design) and posts each new
# batch of lines to a dedicated room, so the captain can watch dispatches,
# escalations, and completions live from any Matrix client.
#
# The bot reuses the alertbot account (same credentials env file as
# alerts.mod.nix) but posts to its own room, which it CREATES on first
# start — private, invites the configured users — and remembers in its
# state directory. Nothing about the room lives in the repo or a secret.
#
# Lines arriving within a 2s window are batched into one message so a
# task fan-out doesn't become a message flood. Send failures are logged
# and dropped — the on-disk log remains canonical; this is a feed, not a
# store. Only lines written after service start are streamed (tail -n 0),
# so restarts never replay history into the room.
{
  flake.nixosModules.fleet-log-stream =
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

      cfg = config.fleetLogStream;
      fleetLog = "/var/lib/agents/tasks/log";
    in
    {
      options.fleetLogStream = {
        enable = mkEnableOption "streaming the fleet audit log to a Matrix room";

        credentialsEnvFile = mkOption {
          type = types.path;
          description = ''
            agenix env file with MATRIX_USER=@bot:server and
            MATRIX_PASSWORD=... — normally the same file the alerts
            aspect uses (any ALERT_ROOM_ID in it is ignored here).
          '';
        };

        homeserverUrl = mkOption {
          type = types.str;
          default = "http://127.0.0.1:6167";
          description = "Homeserver base URL (default: the loopback tuwunel).";
        };

        roomName = mkOption {
          type = types.str;
          default = "Fleet Ops";
          description = "Display name for the room the bot creates on first start.";
        };

        inviteUsers = mkOption {
          type = types.listOf types.str;
          description = "Matrix ids invited to the feed room when it is first created.";
        };
      };

      config = mkIf cfg.enable {
        systemd.services.fleet-log-stream = {
          description = "Stream the fleet audit log to Matrix";
          wantedBy = [ "multi-user.target" ];
          # The log file is created by tmpfiles at boot; no ordering needed
          # beyond the network-facing homeserver being reachable — and even
          # that only costs dropped batches, not a crash.
          startLimitIntervalSec = 0;
          serviceConfig = {
            DynamicUser = true;
            StateDirectory = "fleet-log-stream";
            EnvironmentFile = cfg.credentialsEnvFile;
            Restart = "always";
            RestartSec = 10;
          };
          path = [
            pkgs.coreutils
            pkgs.curl
            pkgs.jq
          ];
          script = ''
            hs=${lib.escapeShellArg cfg.homeserverUrl}
            state=/var/lib/fleet-log-stream

            mcurl() {
              curl -sf --connect-timeout 5 --max-time 30 \
                -H "Content-Type: application/json" "$@"
            }

            tok=$(mcurl -X POST "$hs/_matrix/client/v3/login" \
              -d "$(jq -n --arg u "$MATRIX_USER" --arg p "$MATRIX_PASSWORD" \
                '{type:"m.login.password",identifier:{type:"m.id.user",user:$u},password:$p}')" \
              | jq -er .access_token)
            trap 'mcurl -X POST -H "Authorization: Bearer $tok" "$hs/_matrix/client/v3/logout" -d "{}" > /dev/null || true' EXIT

            # First start: create the private feed room, invite the crew,
            # remember the id. The room is the bot's own — no secret, no
            # repo state. If creation fails, exit and let Restart retry.
            if [ ! -s "$state/room-id" ]; then
              room_id=$(mcurl -X POST -H "Authorization: Bearer $tok" \
                "$hs/_matrix/client/v3/createRoom" \
                -d "$(jq -n --arg n ${lib.escapeShellArg cfg.roomName} \
                  --argjson inv ${lib.escapeShellArg (builtins.toJSON cfg.inviteUsers)} \
                  '{name:$n, preset:"private_chat", invite:$inv,
                    topic:"Live fleet audit log — every SUBMIT/DISPATCH/ESCALATE/STEER/ANSWER/DONE as it happens"}')" \
                | jq -er .room_id)
              printf '%s\n' "$room_id" > "$state/room-id"
            fi
            room=$(jq -rn --arg r "$(cat "$state/room-id")" '$r|@uri')

            send() {
              mcurl -X PUT -H "Authorization: Bearer $tok" \
                "$hs/_matrix/client/v3/rooms/$room/send/m.room.message/$(date +%s%N)-$$" \
                -d "$(jq -n --arg b "$1" '{msgtype:"m.text",body:$b}')" > /dev/null \
                || echo "send failed, batch dropped" >&2
            }

            # Stream: first line of a batch blocks indefinitely; once one
            # arrives, keep absorbing lines until 2s of quiet, then post
            # the batch as a single message.
            batch=""
            while IFS= read -r line; do
              batch="$line"
              while IFS= read -r -t 2 more; do
                batch="$batch
            $more"
              done
              send "$batch"
              batch=""
            done < <(tail -F -n 0 ${fleetLog} 2>/dev/null)
          '';
        };
      };
    };
}
