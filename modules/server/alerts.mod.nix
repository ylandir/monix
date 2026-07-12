# Matrix alerting aspect — failures on this host get posted to a Matrix room
# instead of sitting invisibly in the journal. Two triggers:
#
#   1. A GLOBAL systemd drop-in (service.d/, shipped via systemd.packages —
#      environment.etc can't nest under the generated /etc/systemd/system)
#      attaches OnFailure=alert-unit-failure@%n to every system service, so
#      any failure posts the unit name and a journal tail within seconds.
#   2. A 6-hourly sweep posts still-failed units and filesystems over the
#      disk threshold (what OnFailure can't see: units already failed at
#      boot, creeping disk usage).
#
# Delivery is a curl script against the LOOPBACK homeserver (tuwunel :6167,
# same egress story as budgetbot): password login, join (idempotent), send,
# logout (so devices don't accumulate). The bot holds exactly one
# credential — its own Matrix account. If the homeserver itself is down,
# alerts can't send; accepted — meta-monitoring needs an off-host watcher,
# which this deliberately is not.
#
# The env secret carries MATRIX_USER, MATRIX_PASSWORD, and ALERT_ROOM_ID —
# room id included so nothing about the room lives in the repo and the
# host wiring can gate on the one secret existing.
{
  flake.nixosModules.alerts =
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

      cfg = config.alerts;

      # alert-send <message>: post one m.text to the alert room.
      alertSend = pkgs.writeShellApplication {
        name = "alert-send";
        runtimeInputs = [
          pkgs.curl
          pkgs.jq
        ];
        text = ''
          hs=${lib.escapeShellArg cfg.homeserverUrl}
          room=$(jq -rn --arg r "$ALERT_ROOM_ID" '$r|@uri')

          tok=$(curl -sf -X POST "$hs/_matrix/client/v3/login" \
            -d "$(jq -n --arg u "$MATRIX_USER" --arg p "$MATRIX_PASSWORD" \
              '{type:"m.login.password",identifier:{type:"m.id.user",user:$u},password:$p}')" \
            | jq -r .access_token)

          curl -sf -X POST -H "Authorization: Bearer $tok" \
            "$hs/_matrix/client/v3/join/$room" -d '{}' > /dev/null || true

          # Idempotent self-rename: registration appended tuwunel's default
          # display-name suffix; keep the bot's name plain.
          curl -sf -X PUT -H "Authorization: Bearer $tok" \
            "$hs/_matrix/client/v3/profile/$(jq -rn --arg u "$MATRIX_USER" '$u|@uri')/displayname" \
            -d '{"displayname":"alertbot"}' > /dev/null || true

          curl -sf -X PUT -H "Authorization: Bearer $tok" \
            "$hs/_matrix/client/v3/rooms/$room/send/m.room.message/$(date +%s%N)" \
            -d "$(jq -n --arg b "$1" '{msgtype:"m.text",body:$b}')" > /dev/null

          curl -sf -X POST -H "Authorization: Bearer $tok" \
            "$hs/_matrix/client/v3/logout" -d '{}' > /dev/null || true
        '';
      };

      # The zz- drop-in sorts after 99- within the alert unit's own drop-in
      # set and clears OnFailure there, so a broken alert path can't
      # recurse; the script guard below is the second line of defense.
      onFailureDropins = pkgs.runCommand "alert-onfailure-dropins" { } ''
        mkdir -p $out/etc/systemd/system/service.d
        mkdir -p "$out/etc/systemd/system/alert-unit-failure@.service.d"
        cat > $out/etc/systemd/system/service.d/99-alert-on-failure.conf <<'EOF'
        [Unit]
        OnFailure=alert-unit-failure@%n.service
        EOF
        cat > "$out/etc/systemd/system/alert-unit-failure@.service.d/zz-no-self-alert.conf" <<'EOF'
        [Unit]
        OnFailure=
        EOF
      '';

      hostname = config.networking.hostName;
    in
    {
      options.alerts = {
        enable = mkEnableOption "Matrix alerts for unit failures and disk usage";

        credentialsEnvFile = mkOption {
          type = types.path;
          description = ''
            agenix env file with MATRIX_USER=@bot:server,
            MATRIX_PASSWORD=..., and ALERT_ROOM_ID=!...:server — the alert
            bot's account (its only credential) and the room it posts to.
          '';
        };

        homeserverUrl = mkOption {
          type = types.str;
          default = "http://127.0.0.1:6167";
          description = "Homeserver base URL (default: the loopback tuwunel).";
        };

        diskPercentThreshold = mkOption {
          type = types.ints.between 1 99;
          default = 85;
          description = "Sweep alerts when a real filesystem exceeds this use%.";
        };
      };

      config = mkIf cfg.enable {
        systemd.packages = [ onFailureDropins ];

        systemd.services."alert-unit-failure@" = {
          description = "Post %i failure to the Matrix alert room";
          serviceConfig = {
            Type = "oneshot";
            EnvironmentFile = cfg.credentialsEnvFile;
          };
          scriptArgs = "%i";
          path = [ pkgs.systemd ];
          script = ''
            unit="$1"
            case "$unit" in alert-*) exit 0 ;; esac
            tail=$(journalctl -u "$unit" -n 12 --no-pager -o cat || true)
            msg=$(printf '🔴 %s: %s failed\n%s' ${hostname} "$unit" "$tail")
            ${getExe alertSend} "$msg"
          '';
        };

        systemd.services.alert-sweep = {
          description = "Sweep for failed units and full disks";
          serviceConfig = {
            Type = "oneshot";
            EnvironmentFile = cfg.credentialsEnvFile;
          };
          path = [
            pkgs.systemd
            pkgs.gawk
            pkgs.coreutils
          ];
          script = ''
            problems=""

            failed=$(systemctl --failed --no-legend --plain | awk '{print $1}')
            if [ -n "$failed" ]; then
              problems=$(printf '🔴 failed units:\n%s' "$failed")
            fi

            full=$(df --local -x tmpfs -x devtmpfs -x efivarfs \
              --output=pcent,target | tail -n +2 \
              | awk -v t=${toString cfg.diskPercentThreshold} \
                  '{ gsub(/%/,"",$1); if ($1+0 >= t) print $1 "% " $2 }')
            if [ -n "$full" ]; then
              problems=$(printf '%s\n💾 disk over ${toString cfg.diskPercentThreshold}%%:\n%s' "$problems" "$full")
            fi

            if [ -n "$problems" ]; then
              msg=$(printf '%s sweep:\n%s' ${hostname} "$problems")
              ${getExe alertSend} "$msg"
            fi
          '';
        };

        systemd.timers.alert-sweep = {
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnBootSec = "10min";
            OnUnitActiveSec = "6h";
          };
        };
      };
    };
}
