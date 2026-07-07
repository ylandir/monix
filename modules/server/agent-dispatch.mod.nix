# Agent-fleet dispatcher. See docs/agent-fleet.md. Turns the fleet into a
# drop-a-file service: a task is a markdown prompt placed in the queue
# directory; a worker runs it on a pristine VM and the report comes back —
# no SSH into guests, no forge in the loop.
#
#   /var/lib/agents/tasks/queue/<name>.md   <- drop tasks here (wheel-writable;
#                                              write elsewhere and `mv` in, so
#                                              a half-written file is never seen)
#   /var/lib/agents/tasks/done/<id>/        <- prompt.md + report.md + agent.log
#   /var/lib/agents/tasks/failed/<id>/      <- same, for nonzero exit or timeout
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
      inherit (lib.options) mkOption;
      inherit (lib.strings) concatMapStringsSep;
      inherit (lib) types;

      cfg = config.agentFleet;

      tasksDir = "/var/lib/agents/tasks";

      drainerFor =
        worker:
        let
          work = "/var/lib/agents/work/${worker}/task";
        in
        {
          description = "Drain the agent task queue on worker ${worker}";
          path = [
            pkgs.coreutils
            pkgs.systemd
          ];
          serviceConfig = {
            Type = "oneshot";
            Slice = "agents.slice";
          };
          script = ''
            queue=${tasksDir}/queue
            running=${tasksDir}/running/${worker}
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
              set -- "$queue"/*.md
              if [ ! -e "$1" ]; then
                break
              fi
              id="$(basename "$1" .md)-$(date +%Y%m%d-%H%M%S)"
              # Atomic claim: with several drainers racing for the same
              # task file, exactly one rename succeeds; losers re-scan.
              if ! mv "$1" "$running/$id.md" 2>/dev/null; then
                continue
              fi
              echo "dispatching $id to ${worker}"

              stop_vm
              reset_work
              install -m 0444 "$running/$id.md" "$work/prompt.md"
              if ! systemctl start microvm@${worker}.service; then
                echo "worker ${worker} failed to start; filing $id as failed"
                stop_vm
                out=${tasksDir}/failed/$id
                install -d "$out"
                mv "$running/$id.md" "$out/prompt.md"
                continue
              fi

              deadline=$(( $(date +%s) + ${toString cfg.taskTimeout} ))
              status=timeout
              while [ "$(date +%s)" -lt "$deadline" ]; do
                if [ -f "$work/exit-code" ]; then
                  if [ "$(cat "$work/exit-code")" = 0 ]; then
                    status=done
                  else
                    status=failed
                  fi
                  break
                fi
                # An ask-cockpit question is pending: kick the answerer.
                # (This poll is the trigger — inotify path units can't watch
                # this deep. Re-kicking while it runs is a no-op.)
                set -- "$work"/question-*.md
                if [ -e "$1" ]; then
                  systemctl start --no-block agent-guidance.service
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
              echo "$id finished: $status -> $out"
            done
          '';
        };
    in
    {
      options.agentFleet.taskTimeout = mkOption {
        type = types.int;
        default = 5400;
        description = "seconds a task may run before the worker is stopped and the task filed as failed";
      };

      options.agentFleet.guidanceModel = mkOption {
        type = types.str;
        default = "opus";
        description = "model that answers workers' ask-cockpit questions";
      };

      config = mkIf (cfg.enable && cfg.workers != [ ]) {
        systemd.tmpfiles.rules = [
          "d ${tasksDir} 0755 root root -"
          # The cockpit user (wheel) drops tasks and reads results.
          "d ${tasksDir}/queue 0770 root wheel -"
          "d ${tasksDir}/running 0755 root root -" # per-worker subdirs, created by drainers
          "d ${tasksDir}/done 0755 root root -"
          "d ${tasksDir}/failed 0755 root root -"
        ];

        systemd.paths.agent-dispatcher = {
          description = "Watch the agent task queue";
          wantedBy = [ "multi-user.target" ];
          pathConfig.DirectoryNotEmpty = "${tasksDir}/queue";
        };


        systemd.services = {
          # The path-triggered starter: kick every worker's drainer (no-op
          # for drainers already running) and exit, so the path unit can
          # re-trigger for later arrivals.
          agent-dispatcher = {
            description = "Start a queue drainer per agent worker";
            path = [ pkgs.systemd ];
            serviceConfig.Type = "oneshot";
            script = "systemctl start --no-block ${
              concatMapStringsSep " " (w: "agent-dispatch-${w.name}.service") cfg.workers
            }";
          };
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
            ];
            serviceConfig = {
              Type = "oneshot";
              User = config.primaryUser;
              Group = "users";
              Slice = "agents.slice";
            };
            script = ''
              for q in /var/lib/agents/work/*/task/question-*.md; do
                if [ ! -e "$q" ]; then
                  continue
                fi
                dir="$(dirname "$q")"
                n="$(basename "$q" .md)"
                n="''${n#question-}"
                answer="$dir/answer-$n.md"
                echo "answering $q"

                guidance="$(
                  timeout 300 claude -p \
                    "You supervise a fleet of sandboxed coding/research agents. One of them is working on the task below and has asked you a question. Give concise, decisive guidance it can act on immediately.

              == THE AGENT'S TASK ==
              $(cat "$dir/prompt.md" 2>/dev/null || echo "(prompt unavailable)")

              == THE AGENT'S QUESTION ==
              $(cat "$q")" \
                    --model ${cfg.guidanceModel} \
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
