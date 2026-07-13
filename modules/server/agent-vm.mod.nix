# Agent-fleet worker guests. See docs/agent-fleet.md. Each worker is a
# minimal, purpose-built NixOS microVM — deliberately NOT composed from
# self.nixosModules (workers are not fleet hosts; no tailnet, no monorepo,
# no host secrets, by absence). Claude Code runs fully-permissioned inside;
# containment is the host's default-deny egress, not anything the guest
# promises: the guest has no default route and no DNS, so the squid
# allowlist proxy on the bridge IP is structurally the only way out.
#
# Ephemerality: the guest root is tmpfs (microvm.nix default) and the nix
# store is the host's, read-only over virtiofs. The two volume images (store
# overlay + /workspace scratch) are deleted on every VM start (ExecStartPre
# below; the runner recreates them blank), so nothing an agent writes
# survives a restart — a compromised or wedged worker is one
# `systemctl restart microvm@<name>` from pristine.
#
# CREDENTIALS: idle guests have an empty read-only credential share. After a
# task is claimed, the host drainer stages exactly the selected executor's
# credential and publishes prompt.md last. The guest validates and installs
# that one credential into the executor's private home; local tasks receive
# none. The VM is stopped before the host clears the share. Never put secrets
# in the nix store — guests read the ENTIRE host store.
{
  flake.nixosModules.agent-guests =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      inherit (lib.attrsets) listToAttrs mapAttrsToList nameValuePair optionalAttrs;
      inherit (lib.lists) concatLists concatMap singleton;
      inherit (lib.meta) getExe getExe';
      inherit (lib.modules) mkForce mkIf;
      inherit (lib.options) mkOption;
      inherit (lib.strings) concatMapStringsSep fixedWidthString optionalString;
      inherit (lib) types;

      guide = import ../../lib/fleet-guide.nix;
      hintFile = pkgs.writeText "worker-hint.md" (guide.system + guide.worker);

      cfg = config.agentFleet;

      hostAddr = "10.100.0.1";
      proxyUrl = "http://${hostAddr}:3128";
      # Direct (non-proxied) guest destinations: local inference bypasses
      # squid — it's plain HTTP to a bridge IP, which the CONNECT allowlist
      # could never express; the br-agents pinhole is its firewall instead.
      noProxy = "127.0.0.1,localhost,${hostAddr}";

      # Guest opencode configuration. When the host serves local inference
      # (inference.mod.nix), expose it to opencode as a `local` provider —
      # the model catalog (and its aliases) is generated from the SAME
      # inference.models the host serves, so guest model ids can never
      # drift from what llama-swap actually offers. Dispatch as
      # `agent: opencode` + `model: local/<name>`. The ai-sdk loader wants
      # a non-empty apiKey; llama-swap ignores it.
      opencodeConfig = pkgs.writeText "opencode.json" (
        builtins.toJSON (
          {
            "$schema" = "https://opencode.ai/config.json";
          }
          // optionalAttrs config.inference.enable {
            provider.local = {
              npm = "@ai-sdk/openai-compatible";
              name = "ship-local inference (llama-swap)";
              options = {
                baseURL = "http://${hostAddr}:${toString config.inference.port}/v1";
                apiKey = "local";
              };
              models = listToAttrs (
                concatLists (
                  mapAttrsToList (n: m: map (id: nameValuePair id { }) ([ n ] ++ m.aliases)) config.inference.models
                )
              );
            };
          }
        )
      );

      credsDir = name: "/run/agents/creds/${name}";
      guestCredsMount = "/run/host-creds";

      # Per-worker task exchange: the dispatcher (agent-dispatch.mod.nix)
      # writes prompt.md here before booting the VM; the guest's agent-task
      # unit writes report.md/agent.log/exit-code back, and ask-cockpit
      # exchanges question-N.md/answer-N.md through it mid-task. The guest
      # `agent` user is uid 1000/gid 100, which passes through virtiofs
      # verbatim, so the host-side directory is owned by uid 1000.
      workDir = name: "/var/lib/agents/work/${name}/task";
      guestTaskMount = "/run/task";

      # Per-worker volume images, wiped on every VM start (see ExecStartPre).
      volumes = [
        {
          image = "nix-overlay.img"; # writable nix-store overlay
          mountPoint = "/nix/.rw-store";
          size = 8192;
        }
        {
          image = "workspace.img"; # the agent's scratch checkout/build dir
          mountPoint = "/workspace";
          size = 20480;
        }
      ];

      # One worker class per repo; `index` numbers workers within the fleet
      # and derives both the bridge address (10.100.0.10+index) and a
      # locally-administered MAC. The decimal index doubles as the MAC's
      # last octet — unique for index <= 99, which is plenty.
      mkAgentGuest =
        {
          name,
          index,
          vcpu,
          mem,
          ...
        }:
        let
          addr = "10.100.0.${toString (10 + index)}";
          mac = "02:00:00:00:00:${fixedWidthString 2 "0" (toString index)}";
        in
        {
          # The generated microvm unit does not autostart itself; its resident
          # drainer owns lifecycle and maintains it as part of the warm pool.
          autostart = false;

          config =
            { pkgs, ... }:
            let
              # Mid-task escalation: writes a question into the task share and
              # blocks until the host's guidance service (agent-dispatch.mod.nix)
              # answers it with a stronger model. Capped per task so a confused
              # agent can't burn the cockpit's quota in a loop.
              askCockpit = pkgs.writeShellApplication {
                name = "ask-cockpit";
                text = ''
                  if [ $# -lt 1 ]; then
                    echo "usage: ask-cockpit <question...>" >&2
                    exit 2
                  fi
                  task=${guestTaskMount}
                  n=1
                  while [ -e "$task/question-$n.md" ] || [ -e "$task/answer-$n.md" ]; do
                    n=$((n + 1))
                    if [ "$n" -gt 5 ]; then
                      echo "guidance limit (5 questions) reached for this task; proceed on your best judgment" >&2
                      exit 1
                    fi
                  done
                  printf '%s\n' "$*" > "$task/question-$n.md.tmp"
                  mv "$task/question-$n.md.tmp" "$task/question-$n.md"
                  # 30 min: a `guidance: cockpit` task is answered by the live
                  # cockpit (possibly a human), which is slower than a model
                  # advisor. The loop exits the moment an answer lands.
                  for _ in $(seq 1 360); do
                    if [ -e "$task/answer-$n.md" ]; then
                      cat "$task/answer-$n.md"
                      exit 0
                    fi
                    sleep 5
                  done
                  echo "no guidance arrived within 30 minutes; proceed on your best judgment"
                '';
              };

              claudeExecutor = pkgs.writeShellApplication {
                name = "agent-claude-exec";
                text = ''
                  # shellcheck disable=SC1091
                  . /run/agent-claude/env
                  exec ${getExe pkgs.claude-code} "$@"
                '';
              };

              codexExecutor = pkgs.writeShellApplication {
                name = "agent-codex-exec";
                text = ''
                  exec ${getExe pkgs.codex} "$@"
                '';
              };

              opencodeExecutor = pkgs.writeShellApplication {
                name = "agent-opencode-exec";
                text = ''
                  # shellcheck disable=SC1091
                  [ ! -r /run/agent-opencode/env ] || . /run/agent-opencode/env
                  exec ${getExe pkgs.opencode} "$@"
                '';
              };

              localExecutor = pkgs.writeShellApplication {
                name = "agent-local-exec";
                text = ''
                  exec ${getExe pkgs.opencode} "$@"
                '';
              };
            in
            {
              microvm = {
                hypervisor = "cloud-hypervisor";
                inherit vcpu mem;

                # Unique per-VM vsock context ID (any u32 >= 3); lets the
                # guest's systemd send readiness notifications to the runner.
                # The host side is a unix socket in the VM's state dir, not a
                # network path out.
                vsock.cid = 100 + index;

                interfaces = singleton {
                  type = "tap";
                  id = "vm-${name}"; # enslaved to br-agents by the networkd vm-* match
                  inherit mac;
                };

                shares = [
                  # The host's store, read-only. Note this exposes the ENTIRE
                  # host store to the guest — never put secrets in the store.
                  {
                    proto = "virtiofs";
                    tag = "ro-store";
                    source = "/nix/store";
                    mountPoint = "/nix/.ro-store";
                  }
                   # Empty while idle; the host drainer atomically stages only
                   # the credential selected by the claimed task before it
                   # publishes prompt.md.
                  {
                    proto = "virtiofs";
                    tag = "creds";
                    source = credsDir name;
                    mountPoint = guestCredsMount;
                    readOnly = true;
                    cache = "never";
                  }
                  # Task in, report out (see agent-task below).
                  {
                    proto = "virtiofs";
                    tag = "task";
                    source = workDir name;
                    mountPoint = guestTaskMount;
                    # Warm pool delivers prompt.md into a RUNNING guest. With
                    # default caching the guest keeps a stale negative dentry for
                    # a never-existed file it stats without ever touching the dir,
                    # so it never sees the host's write. cache=never makes the
                    # guest always revalidate against the host. (Tiny control-
                    # plane share, so no meaningful perf cost.)
                    cache = "never";
                  }
                ];

                # Writable overlay so `nix build` works inside the guest.
                writableStoreOverlay = "/nix/.rw-store";
                inherit volumes;
              };

              # NETWORKING — static address on the host-only bridge subnet,
              # deliberately NO gateway and NO DNS: the guest cannot route or
              # resolve anything. Squid does all resolving on its behalf.
              networking.useNetworkd = true;
              networking.useDHCP = false;
              systemd.network.networks."20-lan" = {
                matchConfig.MACAddress = mac;
                address = singleton "${addr}/24";
              };

              # Everything HTTP(S) goes through the proxy. networking.proxy
              # covers the lowercase env vars plus nix-daemon; Claude Code and
              # Codex (Node) want the uppercase forms, set explicitly.
              networking.proxy.default = proxyUrl;
              networking.proxy.noProxy = noProxy;
              environment.variables = {
                HTTP_PROXY = proxyUrl;
                HTTPS_PROXY = proxyUrl;
                NO_PROXY = noProxy;
                # opencode reads its provider catalog (incl. the host's local
                # inference endpoint) from this read-only store path.
                OPENCODE_CONFIG = "${opencodeConfig}";
              };

              environment.systemPackages = [
                askCockpit
                claudeExecutor
                codexExecutor
                opencodeExecutor
                localExecutor
                pkgs.git
                pkgs.ripgrep
                pkgs.fd
                pkgs.jq
                # usage.json extraction reads opencode's SQLite store
                pkgs.sqlite
                pkgs.curl
                pkgs.gnumake
                pkgs.gcc
                pkgs.gnutar
                pkgs.procps
                pkgs.util-linux
                pkgs.zstd
              ];

              nix.settings.experimental-features = [
                "flakes"
                "nix-command"
              ];
              # Substituters stay at the default cache.nixos.org — the only
              # cache on the egress allowlist (.nixos.org).

              # TASK RUNNER — if the dispatcher staged a prompt in the task
              # share before boot, run it headless as the agent user and
              # write the results back. One task per VM lifetime: the volumes
              # are wiped on start, so boot state is always pristine and this
              # unit's ConditionPathExists decides whether this is a task run
              # or an idle/debugging boot.
              # Type=exec, NOT oneshot: the guest's pid1 reports readiness to
              # the VMM (the VM unit is Type=notify via vsock) only once the
              # boot transaction settles, and a oneshot's start job lasts for
              # the whole task — a long task would hold the host-side
              # `systemctl start microvm@<name>` until its 150s timeout. An
              # exec start job completes at fork, so boot settles in seconds
              # while the task runs on.
              systemd.services.agent-task = {
                description = "Run the dispatched task";
                wantedBy = [ "multi-user.target" ];
                unitConfig = {
                  # No ConditionPathExists on prompt.md: the guest boots idle and
                  # the wait loop in the script blocks until the host delivers a
                  # task, so gating the unit on the file existing would skip it
                  # entirely on a warm (empty-share) boot.
                  RequiresMountsFor = [ guestTaskMount guestCredsMount ];
                };
                # The full system path, not a minimal tool list: the agent's
                # shell inherits this unit's PATH, and it needs everything
                # installed in the guest (git, ask-cockpit, compilers...).
                path = [ "/run/current-system/sw" ];
                serviceConfig = {
                  Type = "exec";
                  User = "root";
                  Group = "root";
                  WorkingDirectory = "/workspace";
                  # Units don't read /etc/set-environment; restate the proxy.
                  # The Bash timeouts let a blocking ask-cockpit call outlive
                  # Claude Code's 2-minute default tool timeout (guidance
                  # takes minutes; killing the wait made agents re-ask).
                  Environment = [
                    "HTTP_PROXY=${proxyUrl}"
                    "HTTPS_PROXY=${proxyUrl}"
                    "NO_PROXY=${noProxy}"
                    "OPENCODE_CONFIG=${opencodeConfig}"
                    "BASH_DEFAULT_TIMEOUT_MS=1200000"
                    "BASH_MAX_TIMEOUT_MS=1800000"
                  ];
                  # Defense in depth alongside the host's aggregate exchange
                  # budget: no single guest-created file may grow unbounded.
                  LimitFSIZE = cfg.taskExchangeMaxBytes;
                };
                # The prompt may start with a front-matter block setting task
                # options; unknown keys are ignored. Currently understood:
                #   ---
                #   agent: claude        <- required executor: claude | codex | opencode
                #   model: sonnet        <- required executor --model value; for
                #                           opencode a provider/model slug, e.g.
                #                           openrouter/moonshotai/kimi-k2
                #   ---
                # New executors are one more case branch below; the contract
                # is only: read prompt body, write report.md + agent.log +
                # exit-code, run with everything auto-approved (the VM is the
                # sandbox — that's the point of the fleet).
                script = ''
                  prompt=${guestTaskMount}/prompt.md

                  # Tell the host drainer that this guest has mounted its task
                  # share and reached the delivery wait loop. systemd reporting
                  # the MicroVM active only proves the VMM is running.
                  touch ${guestTaskMount}/.ready

                  # Warm pool: wait for the host to deliver the task, then run it.
                  # Poll by READING the directory (readdir via ls), NOT by statting
                  # a single never-existed filename. A bare `[ -f prompt.md ]` on a
                  # dir the guest never reads sits on a stale negative-dentry cache
                  # and never sees the host's delivered file; a readdir forces the
                  # guest to revalidate against the host. Confirmed empirically: an
                  # instrumented build that ls'd the dir each poll delivered fine,
                  # where the bare stat-loop hung — even with virtiofs cache=never.
                  # Touch .ready every iteration: it doubles as the IDLE
                  # heartbeat. A long-warm guest that wedges or dies stops
                  # refreshing it, and the drainer (which requires a FRESH
                  # .ready before claiming) recycles this VM instead of
                  # delivering a task into a zombie — long-idle VMs were
                  # observed to rot after ~10h with the unit still active.
                  while ! ls -1 "${guestTaskMount}" 2>/dev/null | grep -Fqx prompt.md; do
                    touch ${guestTaskMount}/.ready
                    sleep 1
                  done

                  credential_error=
                  if [ -L ${guestCredsMount}/task-meta ] || [ ! -f ${guestCredsMount}/task-meta ]; then
                    credential_error=1
                    agent=; model=; effort=
                  else
                    # Host-generated canonical metadata lives in the read-only
                    # credential share; the guest never reparses executor fields.
                    # shellcheck disable=SC1091
                    . ${guestCredsMount}/task-meta
                  fi
                  awk '
                    NR==1 && $0=="---" { h=1; next }
                    h && $0=="---" { h=0; next }
                    h { next }
                    { print }
                  ' "$prompt" > /tmp/prompt-body.md

                  case "$agent" in
                    claude)
                      task_user=agent-claude
                      task_home=/home/agent-claude
                      executor=${getExe claudeExecutor}
                      ;;
                    codex)
                      task_user=agent-codex
                      task_home=/home/agent-codex
                      executor=${getExe codexExecutor}
                      ;;
                    opencode)
                      case "$model" in
                        local/*)
                          task_user=agent-local
                          task_home=/home/agent-local
                          executor=${getExe localExecutor}
                          ;;
                        openrouter/*)
                          task_user=agent-opencode
                          task_home=/home/agent-opencode
                          executor=${getExe opencodeExecutor}
                          ;;
                        *)
                          task_user=
                          task_home=
                          executor=
                          ;;
                      esac
                      ;;
                    *)
                      task_user=
                      task_home=
                      executor=
                      ;;
                  esac

                  # The host publishes prompt.md only after staging the selected
                  # credential. Reject any missing, extra, linked, or wrong file
                  # before copying it into an executor-private location.
                  credential_count=0
                  credential_name=
                  for credential in ${guestCredsMount}/*; do
                    [ -e "$credential" ] || [ -L "$credential" ] || continue
                    if [ "$(basename "$credential")" = task-meta ]; then
                      continue
                    fi
                    credential_count=$((credential_count + 1))
                    credential_name="$(basename "$credential")"
                    if [ -L "$credential" ] || [ ! -f "$credential" ]; then
                      credential_error=1
                    fi
                  done
                  case "$agent:$model" in
                    claude:*) expected_credential=claude-token ;;
                    codex:*) expected_credential=codex-auth.json ;;
                    opencode:openrouter/*) expected_credential=openrouter-key ;;
                    opencode:local/*) expected_credential= ;;
                    *) expected_credential=invalid ;;
                  esac
                  if [ -n "$expected_credential" ]; then
                    if [ "$credential_count" -ne 1 ] || [ "$credential_name" != "$expected_credential" ]; then
                      credential_error=1
                    fi
                  elif [ "$credential_count" -ne 0 ]; then
                    credential_error=1
                  fi
                  if [ -z "$credential_error" ]; then
                    umask 077
                    case "$expected_credential" in
                      claude-token)
                        install -d -m 0700 -o agent-claude -g users /run/agent-claude
                        printf 'export CLAUDE_CODE_OAUTH_TOKEN=%q\n' \
                          "$(cat ${guestCredsMount}/claude-token)" > /run/agent-claude/env
                        chown agent-claude:users /run/agent-claude/env
                        chmod 0400 /run/agent-claude/env
                        ;;
                      codex-auth.json)
                        install -d -m 0700 -o agent-codex -g users /home/agent-codex/.codex
                        install -m 0400 -o agent-codex -g users \
                          ${guestCredsMount}/codex-auth.json /home/agent-codex/.codex/auth.json
                        ;;
                      openrouter-key)
                        install -d -m 0700 -o agent-opencode -g users /run/agent-opencode
                        printf 'export OPENROUTER_API_KEY=%q\n' \
                          "$(cat ${guestCredsMount}/openrouter-key)" > /run/agent-opencode/env
                        chown agent-opencode:users /run/agent-opencode/env
                        chmod 0400 /run/agent-opencode/env
                        ;;
                    esac
                  fi

                  # Heartbeat covers context preparation as well as model work,
                  # so a failed/slow capsule never looks like a dead VM.
                  ( while :; do touch ${guestTaskMount}/.heartbeat; sleep 15; done ) &
                  hbpid=$!

                  # Context is an opaque cockpit-built archive to the host and
                  # is extracted only here, as the selected unprivileged user.
                  baseline=
                  context_error=
                  prepare_context() {
                    # The volume mount can supersede tmpfiles-created metadata;
                    # repair the shared workspace mode after mounts are live.
                    install -d -m 0770 -o "$task_user" -g users /workspace || return
                    runuser -u "$task_user" -- env HOME="$task_home" \
                      tar --extract --zstd --strip-components=1 \
                        --no-same-owner --no-same-permissions --no-overwrite-dir \
                        --directory /workspace --file ${guestTaskMount}/context.tar.zst || return
                    runuser -u "$task_user" -- env HOME="$task_home" git -C /workspace init --quiet || return
                    runuser -u "$task_user" -- env HOME="$task_home" git -C /workspace \
                      config user.name "$task_user" || return
                    runuser -u "$task_user" -- env HOME="$task_home" git -C /workspace \
                      config user.email "$task_user@agents.invalid" || return
                    runuser -u "$task_user" -- env HOME="$task_home" git -C /workspace add -A || return
                    runuser -u "$task_user" -- env HOME="$task_home" git -C /workspace \
                      commit --quiet --allow-empty -m 'fleet context baseline' || return
                    baseline="$(runuser -u "$task_user" -- env HOME="$task_home" \
                      git -C /workspace rev-parse HEAD)" || return
                  }
                  if [ -z "$credential_error" ] && [ -n "$task_user" ] && [ -f ${guestTaskMount}/context.tar.zst ]; then
                    prepare_context > /tmp/context-preparation.log 2>&1 || context_error=1
                  fi

                  hint="$(cat ${hintFile})"

                  rc=0
                  if [ -n "$credential_error" ]; then
                    echo "task rejected: credential set does not match selected executor" | tee ${guestTaskMount}/report.md > ${guestTaskMount}/agent.log
                    rc=66
                  elif [ -n "$context_error" ]; then
                    {
                      echo "task failed: context capsule could not be prepared"
                      cat /tmp/context-preparation.log
                    } | tee ${guestTaskMount}/agent.log > ${guestTaskMount}/report.md
                    rc=65
                  elif [ -z "$task_user" ] || [ -z "$model" ]; then
                    echo "task rejected: agent and model must both be specified" | tee ${guestTaskMount}/report.md > ${guestTaskMount}/agent.log
                    rc=64
                  else
                    case "$agent" in
                      claude)
                        runuser -u "$task_user" -- env HOME="$task_home" "$executor" \
                          -p "$(cat /tmp/prompt-body.md)" --model "$model" \
                          ''${effort:+--effort "$effort"} \
                          --dangerously-skip-permissions \
                          --append-system-prompt "$hint" \
                          > ${guestTaskMount}/report.md \
                          2> ${guestTaskMount}/agent.log || rc=$?
                        ;;
                      codex)
                        # No system-prompt flag; the hint rides atop the prompt.
                        # stdout is the session transcript (-> agent.log); the
                        # final message is the report.
                        runuser -u "$task_user" -- env HOME="$task_home" "$executor" exec \
                          --dangerously-bypass-approvals-and-sandbox \
                          --skip-git-repo-check \
                          --model "$model" \
                          ''${effort:+-c model_reasoning_effort="$effort"} \
                          --output-last-message ${guestTaskMount}/report.md \
                          "$hint

                        $(cat /tmp/prompt-body.md)" \
                          > ${guestTaskMount}/agent.log 2>&1 < /dev/null || rc=$?
                        ;;
                      opencode)
                        # No system-prompt flag; the hint rides atop the prompt
                        # (same as codex). --auto approves every permission (the
                        # VM is the sandbox); stdout is the final response (->
                        # report.md), --print-logs puts the session log on
                        # stderr (-> agent.log). Model is a provider/model slug:
                        # openrouter/<vendor>/<model> (authed by
                        # OPENROUTER_API_KEY from its private executor env) or
                        # local/<name> (the host's llama-swap catalog, via
                        # $OPENCODE_CONFIG — free, ship-local tokens).
                        # effort maps to --variant (provider-specific reasoning
                        # effort; only pass it for models that have variants).
                        runuser -u "$task_user" -- env HOME="$task_home" "$executor" run \
                          --auto \
                          --print-logs \
                          --model "$model" \
                          ''${effort:+--variant "$effort"} \
                          "$hint

                        $(cat /tmp/prompt-body.md)" \
                          > ${guestTaskMount}/report.md \
                          2> ${guestTaskMount}/agent.log < /dev/null || rc=$?
                        ;;
                      *)
                        echo "unknown agent '$agent' (known: claude, codex, opencode)" | tee ${guestTaskMount}/report.md > ${guestTaskMount}/agent.log
                        rc=64
                        ;;
                    esac
                  fi
                  # Distill the executor's own usage records (Claude/codex:
                  # JSONL transcripts; opencode: SQLite) into one normalized
                  # usage.json on the task share, before exit-code signals
                  # completion. Strictly best-effort: a missing or unparsable
                  # store must never fail the task. Field names: input/output
                  # are totals (output includes reasoning); cache_read and
                  # cache_creation follow Anthropic's split, and codex's
                  # cached_input maps to cache_read.
                  if [ -n "$task_user" ]; then
                    usage=""
                    case "$agent" in
                      claude)
                        usage=$(find "$task_home/.claude/projects" -name '*.jsonl' -print0 2>/dev/null \
                          | xargs -0r cat \
                          | jq -cs '
                              [ .[] | select(.type=="assistant" and .message.usage != null)
                                | {id: ((.requestId//"") + "/" + (.message.id//"")), u: .message.usage, m: .message.model} ]
                              | unique_by(.id)
                              | select(length > 0)
                              | { executor: "claude",
                                  model: ((map(.m) | map(select(. != null)) | last) // "unknown"),
                                  input_tokens: (map(.u.input_tokens//0) | add),
                                  output_tokens: (map(.u.output_tokens//0) | add),
                                  cache_read_tokens: (map(.u.cache_read_input_tokens//0) | add),
                                  cache_creation_tokens: (map(.u.cache_creation_input_tokens//0) | add) }' \
                          2>/dev/null) || usage=""
                        ;;
                      codex)
                        # total_token_usage is cumulative per session file:
                        # take each file's final value, then sum the files.
                        usage=$(
                          find "$task_home/.codex/sessions" -name '*.jsonl' -print0 2>/dev/null \
                          | while IFS= read -r -d "" f; do
                              jq -cs '
                                { m: ([ .[] | select(.type=="turn_context") | .payload.model ] | last),
                                  t: ([ .[] | select(.type=="event_msg" and .payload.type=="token_count"
                                              and .payload.info.total_token_usage != null)
                                        | .payload.info.total_token_usage ] | last) }
                                | select(.t != null)' "$f" 2>/dev/null || true
                            done \
                          | jq -cs '
                              select(length > 0)
                              # OpenAI input_tokens INCLUDES cached; normalize
                              # to the Anthropic convention (input = uncached)
                              | { executor: "codex",
                                  model: ((map(.m) | map(select(. != null)) | last) // "unknown"),
                                  input_tokens: ((map(.t.input_tokens//0) | add) - (map(.t.cached_input_tokens//0) | add)),
                                  output_tokens: (map(.t.output_tokens//0) | add),
                                  cache_read_tokens: (map(.t.cached_input_tokens//0) | add),
                                  cache_creation_tokens: 0 }' 2>/dev/null) || usage=""
                        ;;
                      opencode)
                        db=$(find "$task_home/.local/share/opencode" -maxdepth 1 -name '*.db' 2>/dev/null | head -n1)
                        if [ -n "$db" ]; then
                          usage=$(sqlite3 -readonly -json "$db" 'select data from message' 2>/dev/null \
                            | jq -c '
                                [ .[] | .data | fromjson | select(.role=="assistant" and .tokens != null) ]
                                | select(length > 0)
                                | { executor: "opencode",
                                    model: (((map(.providerID) | map(select(. != null)) | last) // "?") + "/"
                                            + ((map(.modelID) | map(select(. != null)) | last) // "unknown")),
                                    input_tokens: (map(.tokens.input//0) | add),
                                    output_tokens: ((map(.tokens.output//0) | add) + (map(.tokens.reasoning//0) | add)),
                                    cache_read_tokens: (map(.tokens.cache.read//0) | add),
                                    cache_creation_tokens: (map(.tokens.cache.write//0) | add) }' \
                            2>/dev/null) || usage=""
                        fi
                        ;;
                    esac
                    if [ -n "$usage" ]; then
                      printf '%s\n' "$usage" > ${guestTaskMount}/usage.json
                    fi
                  fi
                  if [ -n "$task_user" ] && [ -n "$baseline" ] && [ -d /workspace/.git ]; then
                    runuser -u "$task_user" -- env HOME="$task_home" bash -c '
                      git -C /workspace add --intent-to-add --all || true
                      if git -C /workspace diff --binary --no-ext-diff "$1" > "$2/.changes.patch.tmp"; then
                        mv "$2/.changes.patch.tmp" "$2/changes.patch"
                      else
                        rm -f "$2/.changes.patch.tmp"
                      fi
                    ' bash "$baseline" ${guestTaskMount}
                  fi
                  kill "$hbpid" 2>/dev/null || true
                  # The CLI may have left background children. End the selected
                  # UID before root creates the completion marker, so no process
                  # can race a symlink into that root write.
                  pkill -KILL -u "$task_user" 2>/dev/null || true
                  rm -f ${guestTaskMount}/exit-code
                  printf '%s\n' "$rc" > ${guestTaskMount}/exit-code
                '';
              };

              # Local git is used to capture a patch against the cockpit-built
              # baseline. Workers have no forge credentials or GitHub route.
              programs.git = {
                enable = true;
                config = {
                  user.name = name;
                  user.email = "${name}@agents.invalid";
                };
              };

              # Executor identities share the disposable workspace but have
              # private 0700 homes and no wheel/sudo access. Distinct UIDs also
              # prevent ptrace and access to one another's process environments.
              users.users = {
                agent-claude = {
                  isNormalUser = true;
                  homeMode = "0700";
                  description = "Claude fleet executor";
                };
                agent-codex = {
                  isNormalUser = true;
                  homeMode = "0700";
                  description = "Codex fleet executor";
                };
                agent-opencode = {
                  isNormalUser = true;
                  homeMode = "0700";
                  description = "opencode fleet executor";
                };
                agent-local = {
                  isNormalUser = true;
                  homeMode = "0700";
                  description = "credentialless local-model fleet executor";
                };
              };
              systemd.tmpfiles.rules = singleton "d /workspace 0770 root users -";

              # Root autologin on the serial console: reaching the console at
              # all requires host-root (the microvm@ unit's PTY), and guest
              # containment never rests on in-guest auth. Keeps verification
              # and debugging one `microvm -s <name>` away.
              services.getty.autologinUser = "root";

              system.stateVersion = "26.05";
            };
        };
    in
    {
      # The fleet roster. Everything derived from a worker (the VM definition
      # and its slice fence) is generated from this one list.
      options.agentFleet = {
        workers = mkOption {
            description = "agent-fleet worker roster";
          default = [ ];
          type = types.listOf (
            types.submodule {
              options = {
                name = mkOption { type = types.str; };
                index = mkOption { type = types.ints.between 1 99; };
                vcpu = mkOption {
                  type = types.int;
                  default = 8;
                };
                mem = mkOption {
                  type = types.int;
                  default = 8192; # MiB, static — no ballooning
                };
              };
            }
          );
        };

        # Fleet subscription credentials. The host drainer reads these paths at
        # dispatch time and stages only the credential selected by that task.
        credentials = {
          claudeTokenFile = mkOption {
            type = types.str;
            description = "host path of the Claude Code OAuth token (from `claude setup-token`)";
          };
          codexAuthFile = mkOption {
            type = types.str;
            description = "host path of a copy of Codex's auth.json (from a ChatGPT login)";
          };
          openrouterKeyFile = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "host path of an OpenRouter API key (single line, from openrouter.ai/keys); null = opencode dispatch has no credential and fails auth";
          };
        };
      };

      config = mkIf cfg.enable {
        assertions = [
          {
            assertion = lib.lists.length cfg.workers == lib.lists.length (lib.lists.unique (map (w: w.name) cfg.workers));
            message = "agentFleet worker names must be unique";
          }
          {
            assertion = lib.lists.length cfg.workers == lib.lists.length (lib.lists.unique (map (w: w.index) cfg.workers));
            message = "agentFleet worker indices must be unique";
          }
        ];

        microvm.vms = listToAttrs (map (w: nameValuePair w.name (mkAgentGuest w)) cfg.workers);

        # Share sources must exist before virtiofsd starts. The task exchange is
        # guest-writable; the credential source remains root-only and is empty
        # until the drainer stages one credential for a claimed task.
        systemd.tmpfiles.rules = concatMap (w: [
          "d ${workDir w.name} 0770 root users -"
          "d ${credsDir w.name} 0700 root root -"
        ]) cfg.workers;

        systemd.services = listToAttrs (
          map (w:
            # microvm.nix has no slice option; standard unit override so every
            # worker counts against the fleet's 48G/agents.slice fence.
            (nameValuePair "microvm@${w.name}" {
              serviceConfig = {
                Slice = "agents.slice";
                # The drainer owns worker lifecycle; upstream's Restart=always
                # (VMs as long-running services) would fight its stop/start.
                Restart = mkForce "no";
                # Don't attempt a graceful guest poweroff at all — the guest
                # is ephemeral (volumes are wiped on next start), so a clean
                # shutdown buys nothing and the guest's own poweroff is slow.
                # Dropping upstream's microvm-shutdown ExecStop and making
                # SIGKILL the *intended* kill signal means every stop is
                # instant AND records as success. (The previous shape —
                # ExecStop + TimeoutStopSec=3 — killed the VMM just as dead,
                # but systemd logged every stop as result=timeout, a FAILURE,
                # so each task recycle and every switch tripped the global
                # OnFailure Matrix alert: ten spurious alerts per switch.)
                # [ "" ] renders an empty `ExecStop=` assignment, which is
                # systemd's "reset the list" idiom — required because the
                # directive comes from the shared microvm@.service template
                # and a drop-in can only clear it explicitly.
                ExecStop = mkForce [ "" ];
                KillSignal = "SIGKILL";
                TimeoutStopSec = mkForce 3; # vestigial backstop
                # EPHEMERALITY — delete the volume images before every start;
                # the runner's autoCreate recreates them blank (truncate +
                # mkfs), so each boot is a clean slate.
                ExecStartPre = singleton (
                  "${getExe' pkgs.coreutils "rm"} -f "
                  + concatMapStringsSep " " (v: "${config.microvm.stateDir}/${w.name}/${v.image}") volumes
                );
              };
            })
          ) cfg.workers
        );
      };
    };
}
