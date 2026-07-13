# Agent-fleet dispatcher. See docs/agent-fleet.md. Turns the fleet into a
# drop-a-file service: a task is a markdown prompt placed in the queue
# directory; a worker runs it on a pristine VM and the report comes back —
# no SSH into guests, no forge in the loop.
#
#   /var/lib/agents/tasks/queue/<name>.md   <- tasks land here, enqueued by the
#                                              `fleet` tool run as the operator
#                                              user (see fleet-tool.mod.nix); the
#                                              queue is operator-owned, not
#                                              wheel-writable
#   /var/lib/agents/tasks/done/<id>/        <- prompt.md + report.md + agent.log
#   /var/lib/agents/tasks/failed/<id>/      <- same, for nonzero exit or timeout
#   /var/lib/agents/tasks/rejected/         <- quarantined non-regular queue entries
#
# Scheduling: one resident drainer per roster worker maintains a fresh warm VM,
# atomically claims queued tasks, and delivers each prompt into an already-live
# guest. After one task it stops the VM, safely archives bounded output, wipes
# the writable volumes, and boots a fresh idle replacement.
{
  flake.nixosModules.agent-dispatch =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      inherit (lib.attrsets) listToAttrs nameValuePair;
      inherit (lib.modules) mkIf;
      inherit (lib.options) mkOption;
      inherit (lib.strings) optionalString;
      inherit (lib) types;

      cfg = config.agentFleet;
      op = cfg.operatorUser;
      readers = "agent-fleet-readers";

      tasksDir = "/var/lib/agents/tasks";

      # Copy one bounded plain file without ever following a symlink. This is
      # the trust-boundary primitive for guest -> host transfers: opening with
      # O_NOFOLLOW and validating the already-open fd avoids both symlink and
      # check/use races. Destinations must not exist and are created atomically.
      safeTransfer = pkgs.writeTextFile {
        name = "agent-safe-transfer";
        executable = true;
        text = ''
          #!${pkgs.python3}/bin/python3
          import os
          import stat
          import sys

          if len(sys.argv) != 5:
              raise SystemExit("usage: agent-safe-transfer SOURCE DEST MAX_BYTES MODE")

          source, destination, max_bytes, mode = sys.argv[1:]
          max_bytes = int(max_bytes)
          mode = int(mode, 8)
          source_fd = os.open(
              source, os.O_RDONLY | os.O_NONBLOCK | os.O_CLOEXEC | os.O_NOFOLLOW
          )
          destination_fd = None
          try:
              metadata = os.fstat(source_fd)
              if not stat.S_ISREG(metadata.st_mode):
                  raise RuntimeError("source is not a regular file")
              if metadata.st_size > max_bytes:
                  raise RuntimeError(f"source exceeds {max_bytes} bytes")
              destination_fd = os.open(
                  destination,
                  os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC | os.O_NOFOLLOW,
                  mode,
              )
              remaining = max_bytes + 1
              while remaining:
                  chunk = os.read(source_fd, min(1024 * 1024, remaining))
                  if not chunk:
                      break
                  view = memoryview(chunk)
                  while view:
                      written = os.write(destination_fd, view)
                      view = view[written:]
                  remaining -= len(chunk)
              if remaining == 0 and os.read(source_fd, 1):
                  raise RuntimeError(f"source exceeds {max_bytes} bytes")
              os.fsync(destination_fd)
          except Exception:
              if destination_fd is not None:
                  os.close(destination_fd)
                  destination_fd = None
                  try:
                      os.unlink(destination)
                  except FileNotFoundError:
                      pass
              raise
          finally:
              os.close(source_fd)
              if destination_fd is not None:
                  os.close(destination_fd)
        '';
      };

      drainerFor =
        worker:
        let
          work = "/var/lib/agents/work/${worker}/task";
          creds = "/run/agents/creds/${worker}";
        in
        {
          description = "Drain the agent task queue on worker ${worker}";
          # Resident daemon: started at boot, loops forever draining the queue
          # (poll-waits when the queue is empty — see the bottom of the loop),
          # restarted on failure. Replaces the old agent-dispatcher.path +
          # oneshot starter, which wedged under burst submissions (systemd's
          # start-rate-limit failed the .path watcher and it stopped dispatching)
          # and could also miss a DirectoryNotEmpty re-trigger mid-task.
          # startLimitIntervalSec=0 so a crash loop can never make systemd give
          # up on the dispatcher — it must always keep trying to come back.
          wantedBy = [ "multi-user.target" ];
          after = [ "agent-results-permissions.service" ];
          startLimitIntervalSec = 0;
          path = [
            pkgs.coreutils
            pkgs.findutils
            pkgs.gawk
            # completion line reads the guest's usage.json
            pkgs.jq
            pkgs.systemd
          ];
          serviceConfig = {
            Slice = "agents.slice";
            Restart = "always";
            RestartSec = 2;
          };
          script = ''
            queue=${tasksDir}/queue
            running=${tasksDir}/running/${worker}
            rejected=${tasksDir}/rejected
            guidance_root=${tasksDir}/guidance/${worker}
            work=${work}
            creds=${creds}
            ready_dir=/run/agents/ready

            # ORDER MATTERS in the VM cycle: the share directory may only be
            # recreated while the VM (and its virtiofsd) is stopped — pulling
            # it out from under a live virtiofsd wedges it and the VM restart
            # with it.
            stop_vm() {
              systemctl stop microvm@${worker}.service || true
              systemctl reset-failed microvm@${worker}.service 2>/dev/null || true
            }

            reset_work() {
              rm -f "$ready_dir/${worker}"
              rm -rf "$work"
              install -d -m 0770 -o root -g users "$work"
            }

            warm_ready() {
              [ -f "$work/.ready" ] && [ ! -L "$work/.ready" ]
            }

            reset_creds() {
              find "$creds" -mindepth 1 -maxdepth 1 -delete
              chmod 0700 "$creds"
              chown root:root "$creds"
            }

            stage_credential() {
              local source= destination=
              reset_creds
              case "$agent:$model" in
                claude:*) source=${cfg.credentials.claudeTokenFile}; destination=claude-token ;;
                codex:*) source=${cfg.credentials.codexAuthFile}; destination=codex-auth.json ;;
                opencode:openrouter/*)
                  ${optionalString (cfg.credentials.openrouterKeyFile != null) ''
                    source=${cfg.credentials.openrouterKeyFile}; destination=openrouter-key
                  ''}
                  ;;
                opencode:local/*) return 0 ;;
                *) return 1 ;;
              esac
              [ -n "$source" ] || return 0
              install -m 0400 -o root -g root "$source" "$creds/.credential.tmp"
              mv "$creds/.credential.tmp" "$creds/$destination"
            }

            stage_metadata() {
              printf 'agent=%q\nmodel=%q\neffort=%q\n' "$agent" "$model" "$effort" \
                > "$creds/.task-meta.tmp"
              chmod 0400 "$creds/.task-meta.tmp"
              chown root:root "$creds/.task-meta.tmp"
              mv "$creds/.task-meta.tmp" "$creds/task-meta"
            }

            log() {
              echo "$(date '+%F %T') ${worker} $*" | tee -a ${tasksDir}/log
            }

            # Pull a single front-matter value ("agent"/"model") out of a task
            # file, for the audit log. Same block the guest parses to pick the
            # executor (agent-vm.mod.nix); empty if absent.
            fm() {
              awk -v key="$1" '
                NR==1 && $0=="---" { h=1; next }
                h && $0=="---" { exit }
                h && $0 ~ "^"key":" { sub("^"key":[ \t]*",""); print; exit }
              ' "$2" 2>/dev/null
            }

            # Seconds -> "8m1s", for human-readable durations in the log.
            dhms() { printf '%dm%ds' $(( $1 / 60 )) $(( $1 % 60 )); }

            # Collapse a front-matter value to one safe token so a task file
            # can't inject extra space-separated fields into a lifecycle line.
            san() { printf '%s' "$1" | tr -cd 'A-Za-z0-9._/-' | cut -c1-64; }

            # Recover tasks stranded by a previous drainer instance that died
            # mid-task (host switch, failure): requeue them.
            install -d "$running"
            install -d -m 0750 -o root -g users "$guidance_root"
            install -d -m 0755 -o root -g root "$ready_dir"
            for stale in "$running"/*.md; do
              if [ -e "$stale" ]; then
                echo "requeueing stranded $(basename "$stale")"
                stale_id="$(basename "$stale" .md)"
                if [ -f "$running/$stale_id.context.tar.zst" ] && [ ! -L "$running/$stale_id.context.tar.zst" ]; then
                  mv "$running/$stale_id.context.tar.zst" "$queue/$stale_id.context.tar.zst"
                else
                  rm -f "$running/$stale_id.context.tar.zst"
                fi
                mv "$stale" "$queue/"
              fi
            done

            while :; do
              # Warm pool: bring up a FRESH idle VM first (empty share; the guest
              # boots and blocks in its wait loop until a task is delivered), THEN
              # wait for work. One task per VM — it is destroyed and reborn after
              # each task, so isolation is identical to booting per-task; only the
              # boot moves off the task's critical path.
              stop_vm
              reset_work
              reset_creds
              if ! systemctl start microvm@${worker}.service; then
                log "warm boot failed (worker would not start), retrying"
                stop_vm
                sleep 5
                continue
              fi

              # A running VMM is not necessarily ready to receive a task: its
              # guest may still be booting or its agent-task unit may not yet
              # be polling the virtiofs share. Wait for that unit's fresh
              # marker before claiming work, so the task heartbeat deadline
              # never includes a cold or half-ready warm boot.
              ready_deadline=$(( $(date +%s) + ${toString cfg.stallTimeout} ))
              while ! warm_ready; do
                if ! systemctl is-active --quiet microvm@${worker}.service; then
                  log "warm VM died before becoming ready, recycling"
                  continue 2
                fi
                if [ "$(date +%s)" -ge "$ready_deadline" ]; then
                  log "warm VM did not become ready within ${toString cfg.stallTimeout}s, recycling"
                  continue 2
                fi
                sleep 1
              done
              # The guest-writable exchange is intentionally private to root
              # and the task users. Publish only this root-owned readiness bit
              # separately so the unprivileged `fleet health` command can
              # report warm workers without reading task metadata or prompts.
              touch "$ready_dir/${worker}"
              chmod 0644 "$ready_dir/${worker}"

              # Wait for a task WITHOUT rebooting the warm VM (inner loop).
              id=""
              while :; do
                set -- "$queue"/*.md
                # A dangling symlink makes -e false; -L still catches it, so a
                # planted symlink can't masquerade as "queue empty" and strand
                # the real tasks behind it.
                if [ ! -e "$1" ] && [ ! -L "$1" ]; then
                  # Queue empty: poll and re-scan. Stay in THIS loop so the warm
                  # VM is not rebooted; ~2s is invisible next to boot time.
                  sleep 2
                  if ! systemctl is-active --quiet microvm@${worker}.service; then
                    log "warm VM died while idle, recycling"
                    continue 2
                  fi
                  continue
                fi
                # File results under the submitted id verbatim (the fleet tool
                # already guarantees a unique id, so `fleet watch/fetch <id>`
                # resolves by exact match). Only disambiguate a name that would
                # actually collide — e.g. a hand-dropped file reusing an id from
                # an earlier run.
                source_id="$(basename "$1" .md)"
                id="$source_id"
                if [ -e "${tasksDir}/done/$id" ] || [ -e "${tasksDir}/failed/$id" ] || [ -e "$running/$id.md" ]; then
                  id="$id-$(date +%Y%m%d-%H%M%S)-$RANDOM"
                fi
                # Atomic claim: with several drainers racing for the same
                # task file, exactly one rename succeeds; losers re-scan.
                if ! mv "$1" "$running/$id.md" 2>/dev/null; then
                  id=""
                  continue
                fi

                # Defense in depth: only ever process a PLAIN regular file. mv
                # moves a symlink verbatim (it does not dereference), so a
                # symlinked queue entry would otherwise be dereferenced as ROOT
                # by the install below — turning "dispatch a task" into a
                # root-privileged read of the link target (agenix secrets, host
                # keys, other workers' creds). The queue is operator-owned and
                # the fleet tool only ever writes plain files, so this should
                # never fire; if it does, quarantine and move on.
                if [ -L "$running/$id.md" ] || [ ! -f "$running/$id.md" ]; then
                  install -d "$rejected"
                  mv "$running/$id.md" "$rejected/$id.md" 2>/dev/null || rm -f "$running/$id.md"
                  log "rejected $id (non-regular queue entry)"
                  id=""
                  continue
                fi

                context_source="$queue/$source_id.context.tar.zst"
                context_running="$running/$id.context.tar.zst"
                if [ -e "$context_source" ] || [ -L "$context_source" ]; then
                  if ! mv "$context_source" "$context_running" 2>/dev/null \
                    || [ -L "$context_running" ] || [ ! -f "$context_running" ]; then
                    install -d "$rejected"
                    mv "$running/$id.md" "$rejected/$id.md" 2>/dev/null || rm -f "$running/$id.md"
                    rm -f "$context_running" "$context_source"
                    log "rejected $id (unsafe context archive)"
                    id=""
                    continue
                  fi
                else
                  context_running=""
                fi
                break
              done
              start="$(date +%s)"
              seen_q=" "
              guidance_task="$guidance_root/$id"

              # The warm VM could have died while we waited. Delivering into a
              # dead VM would hang the task until the full taskTimeout, so if it
              # is gone, requeue the task and cycle a fresh warm boot instead.
              if ! systemctl is-active --quiet microvm@${worker}.service; then
                log "warm VM died before dispatch, requeueing $id"
                if [ -n "$context_running" ]; then
                  mv -f "$context_running" "$queue/$id.context.tar.zst" 2>/dev/null || true
                fi
                mv -f "$running/$id.md" "$queue/$id.md" 2>/dev/null || true
                continue
              fi
              # Parse the root-owned claimed copy. The guest receives identical
              # bytes but can replace entries in its writable share.
              agent="$(san "$(fm agent "$running/$id.md")")"
              model="$(san "$(fm model "$running/$id.md")")"
              effort="$(san "$(fm effort "$running/$id.md")")"
              guidance="$(san "$(fm guidance "$running/$id.md")")"
              if ! stage_credential; then
                log "rejected $id (unsupported executor credential selection)"
              fi
              stage_metadata
              install -d -m 0770 -o root -g users "$guidance_task"

              # Stage context and the one selected credential first. Publish
              # prompt.md LAST so the waiting guest cannot begin with a partial
              # task environment.
              if [ -n "$context_running" ]; then
                ${safeTransfer} "$context_running" "$work/context.tar.zst" ${toString cfg.taskContextMaxBytes} 0444
              fi
              install -m 0444 "$running/$id.md" "$work/.prompt.md.tmp"
              mv -f "$work/.prompt.md.tmp" "$work/prompt.md"
              log "DISPATCH $id agent=$agent''${model:+ model=$model}''${guidance:+ guidance=$guidance}"

              # Heartbeat wait: finish on exit-code; otherwise kill only if the
              # task STALLS (no agent.log growth for stallTimeout) or exceeds the
              # absolute cap (taskTimeout). A task that keeps producing output
              # keeps resetting the stall clock, so long legit work runs as long
              # as it needs (up to the cap) instead of dying at a fixed wall,
              # while a genuinely stuck task dies in ~stallTimeout rather than
              # holding a warm worker for the whole cap.
              hard_deadline=$(( $(date +%s) + ${toString cfg.taskTimeout} ))
              last_progress=$(date +%s)
              last_hb=0
              status=timeout
              while :; do
                now=$(date +%s)
                if [ -e "$work/exit-code" ] || [ -L "$work/exit-code" ]; then
                  if ! ${safeTransfer} "$work/exit-code" "$guidance_task/exit-code" 64 0640; then
                    log "rejected $id exit-code (unsafe or oversized file)"
                    status=failed
                    break
                  fi
                  if [ "$(cat "$guidance_task/exit-code")" = 0 ]; then
                    status=done
                  else
                    status=failed
                  fi
                  break
                fi
                # Liveness signal: the guest's .heartbeat file, touched every ~15s
                # by agent-task while it runs — independent of whether the agent is
                # producing output, so a long thinking block or silent build still
                # counts as alive. No heartbeat for stallTimeout => the VM/agent is
                # genuinely dead, not merely quiet.
                hb=$(stat -c %Y "$work/.heartbeat" 2>/dev/null || echo 0)
                if [ "$hb" != "$last_hb" ]; then
                  last_hb=$hb
                  last_progress=$now
                fi
                if [ $(( now - last_progress )) -ge ${toString cfg.stallTimeout} ]; then
                  log "STALLED $id (no heartbeat for ${toString cfg.stallTimeout}s)"
                  break
                fi
                if [ "$now" -ge "$hard_deadline" ]; then
                  log "CAP $id (hit absolute ${toString cfg.taskTimeout}s cap)"
                  break
                fi

                exchange_size=$(du -sb -- "$work" 2>/dev/null | cut -f1)
                exchange_size="''${exchange_size:-0}"
                if [ "$exchange_size" -gt ${toString cfg.taskExchangeMaxBytes} ]; then
                  log "OVERSIZE $id (task exchange exceeded ${toString cfg.taskExchangeMaxBytes} bytes)"
                  break
                fi

                # An ask-cockpit question is pending: kick the answerer.
                # Never let the host advisor touch the live guest-writable
                # share. Copy bounded regular files into a host-owned spool
                # with O_NOFOLLOW, then let the advisor operate only there.
                set -- "$work"/question-*.md
                if [ -e "$1" ]; then
                  # Log each distinct escalation once, as the agent raises it.
                  for qf in "$work"/question-*.md; do
                    [ -e "$qf" ] || [ -L "$qf" ] || continue
                    qn="$(basename "$qf" .md)"
                    qn="''${qn#question-}"
                    case "$qn" in
                      1 | 2 | 3 | 4 | 5) ;;
                      *) continue ;;
                    esac
                    spool_q="$guidance_task/question-$qn.md"
                    if [ ! -e "$spool_q" ] && [ ! -e "$guidance_task/answer-$qn.md" ]; then
                      if ${safeTransfer} "$qf" "$spool_q" 65536 0640; then
                        chown root:users "$spool_q"
                        if [ ! -e "$guidance_task/prompt.md" ]; then
                          ${safeTransfer} "$running/$id.md" "$guidance_task/prompt.md" 1048576 0640
                          chown root:users "$guidance_task/prompt.md"
                        fi
                        printf '%s\n' "$guidance" > "$guidance_task/guidance-model.tmp"
                        chown root:users "$guidance_task/guidance-model.tmp"
                        chmod 0640 "$guidance_task/guidance-model.tmp"
                        mv "$guidance_task/guidance-model.tmp" "$guidance_task/guidance-model"
                        systemctl start --no-block agent-guidance.service
                      else
                        log "rejected $id question $qn (unsafe or oversized file)"
                      fi
                    fi
                    case "$seen_q" in
                      *" $qn "*) : ;;
                      *)
                        esc_adv="''${guidance:-${cfg.guidanceModel}}"
                        case "$esc_adv" in "" | none | NONE) esc_adv=none ;; esac
                        log "ESCALATE $id question $qn -> $esc_adv"
                        seen_q="$seen_q$qn "
                      ;;
                    esac
                  done
                fi

                # Deliver completed host-spooled answers without following a
                # destination planted by the live guest. O_EXCL makes a
                # pre-existing file or symlink fail closed.
                for af in "$guidance_task"/answer-*.md; do
                  [ -e "$af" ] || continue
                  an="$(basename "$af" .md)"
                  an="''${an#answer-}"
                  case "$an" in
                    1 | 2 | 3 | 4 | 5) ;;
                    *) continue ;;
                  esac
                  answer_dest="$work/answer-$an.md"
                  if [ ! -e "$answer_dest" ] && [ ! -L "$answer_dest" ]; then
                    ${safeTransfer} "$af" "$answer_dest" 1048576 0644 \
                      || log "could not deliver $id answer $an safely"
                  fi
                done
                sleep 10
              done
              stop_vm
              reset_creds

              if [ "$status" = done ]; then
                out=${tasksDir}/done/$id
              else
                out=${tasksDir}/failed/$id
              fi
              install -d -m 0750 -o root -g ${readers} "$out"
              mv "$running/$id.md" "$out/prompt.md"
              chown root:${readers} "$out/prompt.md"
              chmod 0640 "$out/prompt.md"

              archive_file() {
                src="$1"
                dst="$2"
                limit="$3"
                [ -e "$src" ] || [ -L "$src" ] || return 0
                if ! ${safeTransfer} "$src" "$dst" "$limit" 0640; then
                  log "rejected $id output $(basename "$src") (unsafe or oversized file)"
                else
                  chown root:${readers} "$dst"
                fi
              }
              archive_file "$work/report.md" "$out/report.md" 10485760
              archive_file "$work/agent.log" "$out/agent.log" 52428800
              archive_file "$work/exit-code" "$out/exit-code" 64
              archive_file "$work/changes.patch" "$out/changes.patch" 52428800
              archive_file "$work/usage.json" "$out/usage.json" 65536
              for f in "$work"/answer-*.md; do
                [ -e "$f" ] || [ -L "$f" ] || continue
                answer_name="$(basename "$f")"
                case "$answer_name" in
                  answer-[1-5].md) archive_file "$f" "$out/$answer_name" 1048576 ;;
                  *) log "rejected $id output $answer_name (invalid answer name)" ;;
                esac
              done
              [ -n "$context_running" ] && rm -f "$context_running"
              rm -rf "$guidance_task"
              reset_work

              # Narrative completion line: how long it ran, how many times it
              # escalated to the guidance model, and whether a report came back.
              esc=0
              for a in "$out"/answer-*.md; do
                [ -f "$a" ] && esc=$(( esc + 1 ))
              done
              dur="$(dhms $(( $(date +%s) - start )))"
              if [ -f "$out/report.md" ]; then
                report="report $(wc -c <"$out/report.md") bytes"
              else
                report="no report"
              fi
              tokens=""
              if [ -f "$out/usage.json" ]; then
                tokens=$(jq -r '", \(.input_tokens + .cache_read_tokens + .cache_creation_tokens) in / \(.output_tokens) out tok (\(.model))"' \
                  "$out/usage.json" 2>/dev/null) || tokens=""
              fi
              log "$(echo "$status" | tr '[:lower:]' '[:upper:]') $id ran $dur, $esc escalation(s), $report$tokens"
            done
          '';
        };
    in
    {
      # Two-part timeout (see the poll loop): a task is killed when it STALLS
      # (no agent.log output for stallTimeout) OR blows the absolute cap
      # (taskTimeout), whichever comes first.
      options.agentFleet.stallTimeout = mkOption {
        type = types.int;
        default = 120; # 2 min — the guest heartbeats every ~15s while alive, so a
        # 2-min gap means the VM/agent is genuinely dead, not merely quiet.
        description = "seconds with no guest heartbeat before a task is treated as stalled/dead and killed";
      };

      options.agentFleet.taskTimeout = mkOption {
        type = types.int;
        default = 21600; # 6h absolute cap / runaway backstop
        description = "absolute max seconds a task may run before the worker is stopped and the task filed as failed, regardless of progress";
      };

      options.agentFleet.taskExchangeMaxBytes = mkOption {
        type = types.int;
        default = 805306368; # 768 MiB: context capsule plus bounded task output
        description = "maximum total bytes in one live worker task exchange before the task is stopped";
      };

      options.agentFleet.taskContextMaxBytes = mkOption {
        type = types.int;
        default = 536870912; # 512 MiB compressed workspace snapshot
        description = "maximum compressed context capsule bytes accepted for one task";
      };

      options.agentFleet.guidanceModel = mkOption {
        type = types.str;
        default = ""; # empty => no fleet-wide default advisor
        description = ''
          Optional fleet-wide default advisor model for ask-cockpit escalations.
          Empty (the default) means there is no default: tasks name their own
          advisor via front-matter `guidance:`, and a task with `guidance: none`
          or no `guidance:` line gets no advisor (escalations are answered
          immediately with "use your own judgment"). A per-task `guidance:`
          always overrides this.
        '';
      };

      config = mkIf (cfg.enable && cfg.workers != [ ]) {
        systemd.tmpfiles.rules = [
          "d ${tasksDir} 0755 root root -"
          # The queue is owned by the unprivileged dispatch operator, NOT
          # wheel: the cockpit enqueues only by running the `fleet` tool as
          # that operator (see fleet-tool.mod.nix). root (the drainer) still
          # has full access regardless of group.
          "d ${tasksDir}/queue 0770 root ${op} -"
          "d ${tasksDir}/running 0755 root root -" # per-worker subdirs, created by drainers
          "d ${tasksDir}/done 0750 root ${readers} -"
          "d ${tasksDir}/failed 0750 root ${readers} -"
          "d ${tasksDir}/rejected 0750 root ${readers} -" # quarantined non-regular queue entries
          # The audit trail — one line per lifecycle event (SUBMIT / DISPATCH
          # / ESCALATE / DONE / FAILED / NOTE). Group-owned by the operator so
          # the `fleet` tool can append SUBMIT/NOTE lines; the root drainer
          # writes the rest. World-readable so `tail -f` from the cockpit
          # works. NOTE: this is an operational record, not tamper-evident
          # evidence — the operator group can rewrite it. Values interpolated
          # into lines are sanitised (see `san`) so a task file can't forge
          # fields, but hardening against a compromised operator rewriting the
          # whole file would require a root-only append helper (a later step).
          "f ${tasksDir}/log 0664 root ${op} -"
        ];

        systemd.services = {
          # One-time migration for archives created before private result modes
          # were enforced at creation. New archives are already correct.
          agent-results-permissions = {
            description = "Restrict agent result archives to fleet readers";
            wantedBy = [ "multi-user.target" ];
            before = map (w: "agent-dispatch-${w.name}.service") cfg.workers;
            path = [
              pkgs.coreutils
              pkgs.findutils
            ];
            unitConfig.ConditionPathExists = "!${tasksDir}/.permissions-v1";
            serviceConfig.Type = "oneshot";
            script = ''
              for dir in ${tasksDir}/done ${tasksDir}/failed ${tasksDir}/rejected; do
                [ -d "$dir" ] || continue
                chown root:${readers} "$dir"
                chmod 0750 "$dir"
                find "$dir" -mindepth 1 -type d -exec chown root:${readers} {} + -exec chmod 0750 {} +
                find "$dir" -type f -exec chown root:${readers} {} + -exec chmod 0640 {} +
              done
              touch ${tasksDir}/.permissions-v1
            '';
          };

          # GUIDANCE — answers workers' ask-cockpit questions with Claude and
          # no tools. The root drainer first transfers untrusted guest files
          # into the host-owned guidance spool with O_NOFOLLOW and size caps;
          # this service never reads or writes the live guest share.
          agent-guidance = {
            description = "Answer workers' ask-cockpit questions";
            path = [
              pkgs.claude-code
              pkgs.coreutils
              pkgs.gawk
            ];
            serviceConfig = {
              Type = "oneshot";
              User = config.primaryUser;
              Group = "users";
              Slice = "agents.slice";
            };
            script = ''
              san() { printf '%s' "$1" | tr -cd 'A-Za-z0-9._/-' | cut -c1-64; }
              for q in ${tasksDir}/guidance/*/*/question-*.md; do
                if [ ! -e "$q" ]; then
                  continue
                fi
                dir="$(dirname "$q")"
                n="$(basename "$q" .md)"
                n="''${n#question-}"
                answer="$dir/answer-$n.md"
                echo "answering $q"

                # The drainer parsed and sanitised the task's advisor choice
                # from the exact prompt delivered to the guest.
                g="$(san "$(cat "$dir/guidance-model" 2>/dev/null)")"
                case "$g" in
                  none | NONE) gmodel="" ;;             # explicit none: no advisor
                  "") gmodel="${cfg.guidanceModel}" ;;  # absent: fleet-wide default (may be empty)
                  *) gmodel="$g" ;;
                esac
                case "$gmodel" in
                  "" | none | NONE)
                    printf '%s\n' "No advisor is configured for this task — proceed on your own best judgment." > "$answer.tmp"
                    mv "$answer.tmp" "$answer"
                    rm -f "$q"
                    continue
                    ;;
                esac

                guidance="$(
                  timeout 300 claude -p \
                    "You supervise a fleet of sandboxed coding/research agents. One of them is working on the task below and has asked you a question. Give concise, decisive guidance it can act on immediately.

              == THE AGENT'S TASK ==
              $(cat "$dir/prompt.md" 2>/dev/null || echo "(prompt unavailable)")

              == THE AGENT'S QUESTION ==
              $(cat "$q")" \
                    --model "$gmodel" \
                    --disallowedTools Bash Edit Write Read Grep Glob Task WebFetch WebSearch NotebookEdit
                )" || guidance="(the supervising model could not be reached; proceed on your best judgment)"

                {
                  echo "## Question"
                  cat "$q"
                  echo
                  echo "## Guidance"
                  printf '%s\n' "$guidance"
                } > "$answer.tmp"
                mv "$answer.tmp" "$answer"
                rm -f "$q"
              done
            '';
          };
        }
        // listToAttrs (map (w: nameValuePair "agent-dispatch-${w.name}" (drainerFor w.name)) cfg.workers);
      };
    };
}
