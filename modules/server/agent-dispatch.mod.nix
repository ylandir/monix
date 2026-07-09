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
# Scheduling: a path unit fires when the queue becomes non-empty and starts
# one drainer per roster worker. Each drainer claims tasks off the queue
# with an atomic rename (losers just re-scan), so tasks run concurrently up
# to the number of workers, and a drainer exits when the queue is empty.
# Per task: stage the prompt into the worker's task share, restart the VM
# (the volume wipe makes it pristine), poll for the guest's exit-code file,
# stop the VM, file the results. The dispatcher owns worker lifecycle — a
# manually started VM will be restarted out from under you when a task
# arrives.
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
      inherit (lib.options) mkOption;      inherit (lib) types;

      cfg = config.agentFleet;
      op = cfg.operatorUser;

      tasksDir = "/var/lib/agents/tasks";

      drainerFor =
        worker:
        let
          work = "/var/lib/agents/work/${worker}/task";
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
          startLimitIntervalSec = 0;
          path = [
            pkgs.coreutils
            pkgs.gawk
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
            work=${work}

            # ORDER MATTERS in the VM cycle: the share directory may only be
            # recreated while the VM (and its virtiofsd) is stopped — pulling
            # it out from under a live virtiofsd wedges it and the VM restart
            # with it.
            stop_vm() {
              systemctl stop microvm@${worker}.service || true
              systemctl reset-failed microvm@${worker}.service 2>/dev/null || true
            }

            reset_work() {
              rm -rf "$work"
              install -d -m 0755 -o 1000 -g 100 "$work"
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
            san() { printf '%s' "$1" | tr -cd 'A-Za-z0-9._-' | cut -c1-40; }

            # Recover tasks stranded by a previous drainer instance that died
            # mid-task (host switch, failure): requeue them.
            install -d "$running"
            for stale in "$running"/*.md; do
              if [ -e "$stale" ]; then
                echo "requeueing stranded $(basename "$stale")"
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
              if ! systemctl start microvm@${worker}.service; then
                log "warm boot failed (worker would not start), retrying"
                stop_vm
                sleep 5
                continue
              fi

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
                  continue
                fi
                # File results under the submitted id verbatim (the fleet tool
                # already guarantees a unique id, so `fleet watch/fetch <id>`
                # resolves by exact match). Only disambiguate a name that would
                # actually collide — e.g. a hand-dropped file reusing an id from
                # an earlier run.
                id="$(basename "$1" .md)"
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
                break
              done
              start="$(date +%s)"
              seen_q=" "

              # The warm VM could have died while we waited. Delivering into a
              # dead VM would hang the task until the full taskTimeout, so if it
              # is gone, requeue the task and cycle a fresh warm boot instead.
              if ! systemctl is-active --quiet microvm@${worker}.service; then
                log "warm VM died before dispatch, requeueing $id"
                mv -f "$running/$id.md" "$queue/$id.md" 2>/dev/null || true
                continue
              fi

              # Deliver the task into the ALREADY-RUNNING VM's share. Write to a
              # temp name and atomically rename so the guest's wait loop never
              # observes a half-written prompt.md.
              install -m 0444 "$running/$id.md" "$work/.prompt.md.tmp"
              mv -f "$work/.prompt.md.tmp" "$work/prompt.md"
              # Read the metadata from the installed, root-owned 0444 copy —
              # the exact bytes the worker will run — not the claimed file,
              # so the logged agent/model can't drift from what's dispatched.
              agent="$(san "$(fm agent "$work/prompt.md")")"
              model="$(san "$(fm model "$work/prompt.md")")"
              guidance="$(san "$(fm guidance "$work/prompt.md")")"
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
                if [ -f "$work/exit-code" ]; then
                  if [ "$(cat "$work/exit-code")" = 0 ]; then
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
                # An ask-cockpit question is pending: kick the answerer.
                # (This poll is the trigger — inotify path units can't watch
                # this deep. Re-kicking while it runs is a no-op.)
                set -- "$work"/question-*.md
                if [ -e "$1" ]; then
                  systemctl start --no-block agent-guidance.service
                  # Log each distinct escalation once, as the agent raises it.
                  for qf in "$work"/question-*.md; do
                    [ -e "$qf" ] || continue
                    qn="$(basename "$qf" .md)"
                    qn="''${qn#question-}"
                    # ask-cockpit numbers questions; ignore anything else (a
                    # compromised guest could plant question-*.md with glob
                    # metacharacters that would corrupt the seen-set match).
                    case "$qn" in
                      "" | *[!0-9]*) continue ;;
                    esac
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
                sleep 10
              done
              stop_vm

              if [ "$status" = done ]; then
                out=${tasksDir}/done/$id
              else
                out=${tasksDir}/failed/$id
              fi
              install -d "$out"
              mv "$running/$id.md" "$out/prompt.md"
              for f in "$work"/report.md "$work"/agent.log "$work"/exit-code "$work"/answer-*.md; do
                if [ -f "$f" ]; then
                  install -m 0644 "$f" "$out/$(basename "$f")"
                fi
              done
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
              log "$(echo "$status" | tr '[:lower:]' '[:upper:]') $id ran $dur, $esc escalation(s), $report"
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
          "d ${tasksDir}/done 0755 root root -"
          "d ${tasksDir}/failed 0755 root root -"
          "d ${tasksDir}/rejected 0755 root root -" # quarantined non-regular queue entries
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
          # GUIDANCE — answers workers' ask-cockpit questions with a stronger
          # model, using the cockpit user's own claude login (which is why it
          # runs as primaryUser, whose uid 1000 also matches the guest agent
          # through virtiofs, so the answer file is writable). Question text
          # comes from inside a guest, i.e. is UNTRUSTED input: the answering
          # claude gets no tools at all — it can only read the passed prompt
          # and produce text. Always answers and removes the question, even
          # on failure, so the path unit cannot retrigger in a loop.
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
              fm() {
                awk -v key="$1" '
                  NR==1 && $0=="---" { h=1; next }
                  h && $0=="---" { exit }
                  h && $0 ~ "^"key":" { sub("^"key":[ \t]*",""); print; exit }
                ' "$2" 2>/dev/null
              }
              san() { printf '%s' "$1" | tr -cd 'A-Za-z0-9._-' | cut -c1-40; }
              for q in /var/lib/agents/work/*/task/question-*.md; do
                if [ ! -e "$q" ]; then
                  continue
                fi
                dir="$(dirname "$q")"
                n="$(basename "$q" .md)"
                n="''${n#question-}"
                answer="$dir/answer-$n.md"
                echo "answering $q"

                # Advisor is chosen per-task by the cockpit (front-matter `guidance:`),
                # read from THIS task's prompt. `none`/absent => no advisor: fall
                # through to the optional fleet-wide default, and if that's empty too,
                # answer immediately so the agent doesn't wait out the ask-cockpit
                # timeout.
                g="$(san "$(fm guidance "$dir/prompt.md")")"
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
