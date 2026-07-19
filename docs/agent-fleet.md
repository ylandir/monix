# The agent fleet on fw0

fw0 is both the captain's cockpit and a host for disposable coding-agent
microVMs. The cockpit chooses an executor, model, and directive; a worker runs
that one task with full permissions inside a fresh VM and returns an untrusted
report. Containment is implemented by the host, not by asking the model to
behave.

The implementation is split by concern:

- `cockpit.mod.nix`: the full-power human seat (tmux/SSH and opencode web).
- `fleet-tool.mod.nix`: the scoped cockpit CLI and unprivileged queue operator.
- `agent-dispatch.mod.nix`: queue scheduling, worker lifecycle, question relay, and results.
- `agent-vm.mod.nix`: disposable guest definition, executors, and credentials.
- `microvm-host.mod.nix`: KVM runner, bridge, firewall, and squid egress proxy.
- `inference.mod.nix`: optional ship-local models exposed to workers.

## Trust boundaries

The cockpit and workers have deliberately different authority:

- The cockpit is the captain's seat. It runs as the primary host user and can
  read that user's home, credentials, and working trees. `max` is also a trusted
  Nix user, so compromise of an authenticated cockpit session should be treated
  as potential host compromise.
- `ai.su.is` reaches opencode through Cloudflare Access, Cloudflare Tunnel,
  loopback nginx, and loopback opencode. The Access policy is external state;
  `opencode-web-access-check` probes `/` and `/session` every five minutes and
  fails visibly if an unauthenticated request no longer redirects to Access.
- Workers are untrusted disposable guests. Guest root is expected and is not a
  boundary. KVM, networking, credentials, host file exchange, and resource
  limits form the boundary.
- Worker reports, logs, and guidance questions are always untrusted input to the
  cockpit, even when the VM remained contained.

## Guest containment

Workers use cloud-hypervisor and a minimal inline NixOS configuration rather
than the host module collection.

- Guest root is tmpfs. The writable Nix overlay and `/workspace` images are
  deleted before every boot and recreated blank.
- Eight bird-named workers form a warm pool. Each boots idle,
  waits for one prompt, runs one task, is destroyed, and is replenished in the
  background. A task never reuses a guest that ran an earlier task.
- Guests have static addresses on `br-agents`, no gateway, and no DNS.
- IPv4 and IPv6 forwarding are explicitly disabled on the host.
- VM tap ports are isolated from one another at the bridge.
- The host firewall admits only squid on TCP 3128 and, when enabled, local
  inference on TCP 8091.
- Squid is the sole internet path. It permits HTTPS destinations needed by the
  configured executors and trusted Nix caches, and logs requests under
  `/var/log/squid/`. GitHub and the general internet are unreachable.
- Guests have no SSH server or authorized keys. The host-root-gated serial
  console is the only interactive entry point.

All VMs, drainers, and squid run in `agents.slice`, capped at 48 GiB real host
memory. Guest RAM is demand-paged, so each VM's 8 GiB setting is a ceiling rather
than an idle reservation.

## Credentials

The host decrypts fleet credentials with agenix, but idle workers receive none.
After atomically claiming a task, the root Rust drainer parses the executor from its
root-owned prompt, clears that worker's root-only credential directory, and
stages exactly one credential. It stages context next and publishes `prompt.md`
last, so the waiting guest cannot begin with a partial task environment. A
read-only, uncached virtiofs share exposes the selected credential to guest root,
which validates the exact filename before installing it into the selected
non-root executor identity:

- `agent-claude`: private Claude OAuth environment under `/run/agent-claude`.
- `agent-codex`: private ChatGPT subscription login under `~/.codex/auth.json`.
- `agent-opencode`: private OpenRouter environment when that optional key exists.
- `agent-local`: credentialless OpenCode execution for `local/...` models.

All four users have private `0700` homes, distinct UIDs, no wheel/sudo access,
and full group access to the same disposable `/workspace`. The fixed root task
launcher maps the validated executor name to exactly one user and runs every
model-controlled tool under that UID. Cross-provider credential reads and
same-UID process inspection are therefore structurally blocked.

Guest root can read the selected task credential, but no other provider
credential is present. Local-model tasks receive an empty credential share. The
host stops the VM before clearing the share, and every new dispatch copies
directly from the current agenix path, so credential rotation takes effect on
the next task without a long-lived assembled copy.

The same read-only share carries a host-generated `task-meta` file containing
the canonical validated executor, model, and effort. The guest consumes this
metadata directly instead of independently reparsing front matter; the submitter
and root drainer retain separate validation at their trust boundaries.

The selected executor can still read its own credential because its subscription
CLI requires it. Generic workers have no attacker-controlled network destination
or forge credential to which they can send it. Their intended outputs are only
the bounded task exchange.

Never place secrets in the Nix store: workers can read the host store through a
read-only virtiofs mount.

## Dispatch

The cockpit does not write the queue directly. `fleet-operator` owns the queue,
and the primary user may run exactly the immutable `fleet` binary as that user
through a scoped `NOPASSWD` sudo rule.

```sh
run() { sudo -n -u fleet-operator fleet "$@"; }

id=$(fleet dispatch fix-lint task.md /path/to/repository)
id=$(run submit fix-lint < task.md)
run watch "$id"                 # background this in cockpit workflows
run fetch "$id"                 # untrusted final report and guidance
run logs "$id"                  # untrusted executor transcript
run peek "$id"                  # live view of a RUNNING task (untrusted mirrors)
run steer "$id" "message"       # queue a mid-task steering message
run answer "$id" 1 "answer"     # answer a pending guidance:cockpit question
run cancel "$id"                # cancel a queued/running task
run patch "$id"                 # bounded automatic git diff
run status                      # recent lifecycle log
run health                      # current queue, workers, units, memory, disk
run note "$id" reviewed-output
```

`submit` reads standard input, limits prompts to 1 MiB, publishes atomically,
and requires explicit `agent` and `model` fields:

```markdown
---
agent: codex
model: gpt-5.5
guidance: none
effort: high
---

Review the target and report concrete findings with file and line references.
```

For code tasks, prefer `fleet dispatch`. It runs as the cockpit user, snapshots
the selected context directory while excluding `.git`, `.direnv`, `result`, and
common local `.env` files, then internally uses the same scoped sudo boundary to
publish a capsule containing `prompt.md` and `context.tar.zst`. The host never
extracts repository context as root. The selected unprivileged guest user
extracts it inside the disposable VM and creates a local baseline commit.

Executors:

- `claude`: a Claude Code model id; subscription authenticated.
- `codex`: an OpenAI Codex model id; ChatGPT subscription authenticated.
- `opencode`: `openrouter/<vendor>/<model>` when metered OpenRouter execution is
  intended, or `local/<name>` for a model declared by `inference.models`.

The cockpit must never silently substitute a provider. If the requested
executor cannot authenticate, fail and report that limitation.

`guidance` is optional and has exactly one meaningful value: `cockpit` routes
escalations to the live cockpit — the drainer publishes the question to the
task's live view, `fleet health` flags it as `questions-pending`, and the
cockpit replies with `fleet answer <id> <n>` (the guest waits up to 30 minutes
before proceeding on its own judgment). Any other or absent value means the
drainer answers `ask-cockpit` immediately with "use your own judgment": there
is no advisor tier, and an unattended drone that is genuinely blocked is
expected to state what is missing in its report and exit.

`timeout` is an optional positive per-task front-matter value capped by the
fleet-wide six-hour maximum. A validated deterministic `task-key` lets a
resubmitted task resolve to the same queued, running, or archived task instead
of duplicating it.

## Live interaction with a running task

Interactivity crosses the same trust boundary as everything else — bounded
files, no-follow transfers, untrusted content — so none of it relaxes
containment:

- **Peek.** The drainer mirrors the guest's `progress.md` (1 MiB cap) and the
  last 64 KiB of `agent.log` into `/var/lib/agents/tasks/live/<id>/` whenever
  they change, using the same no-follow bounded transfer as archival.
  `fleet peek <id>` reads only these host-owned mirrors, never the guest share.
  Workers are instructed to keep `progress.md` current; peek is the intended
  input to the human "thinking vs wedged" judgment the heartbeat cannot make.
- **Steer.** `fleet steer <id> [message]` (64 KiB cap, ≤32 per task) queues a
  cockpit-authored message in the operator spool `tasks/steer/`; the task's
  drainer delivers it into the guest as `message-N.md` and logs `STEERED`.
  Workers are instructed to check for new messages at natural checkpoints and
  before writing the final report; delivery is host-guaranteed, pickup is
  instruction-driven. Numbers are never reused within a task.
- **Answer.** For `guidance: cockpit` tasks, `fleet answer <id> <n>` queues the
  reply in the operator spool `tasks/answers/`; the drainer delivers it into the
  guest exchange as `answer-N.md` and mirrors it to the live view. Question
  numbers remain host-validated to 1–5.

Live artifacts (progress, delivered messages, questions and answers) are
archived with the task result and the live directory is removed. The host never
parses or acts on any of this content — it only displays it to the cockpit and
delivers cockpit-authored files to the guest.

## Scheduling and lifecycle

One resident root Rust drainer exists per worker. It maintains one fresh warm VM,
atomically claims a queued task, verifies the VM is alive, and delivers the
prompt and optional context archive into the already-running task share. The guest notices the prompt by
re-reading the virtiofs directory, runs exactly one executor, and writes an
exit code and outputs.

The guest touches a heartbeat about every 15 seconds. The host stops a task if:

- no heartbeat arrives for 120 seconds;
- the task reaches the six-hour absolute cap; or
- the task exchange exceeds 768 MiB.

Context capsules are capped at 512 MiB compressed, and the guest service has a
768 MiB per-file limit. Archived reports are capped
at 10 MiB, executor logs at 50 MiB, and each guidance question/answer at 64 KiB
and 1 MiB respectively. After the task, the launcher captures tracked, untracked,
committed, and working-tree changes against its in-memory baseline as a binary
`changes.patch`, archived with a 50 MiB cap.

After completion or failure, the drainer stops the VM, builds a hidden bounded
result archive, and atomically publishes it only when complete.
The next loop deletes the VM's writable images and creates a fresh warm guest.

## Host file exchange

The guest-writable task share is a hostile filesystem boundary. The root
dispatcher never directly copies an untrusted path with `cp`, `install`, or a
shell `-f` check. Its Rust bounded-copy primitive opens the source with
`O_NOFOLLOW`, validates the open descriptor as a bounded regular file, and
creates a new destination with `O_EXCL` and `O_NOFOLLOW`.

Completed prompts, reports, logs, patches, and answers are mode `0640` under directories
mode `0750`, readable only by root and `agent-fleet-readers` (`max` and
`fleet-operator`).

A stamped one-time migration repairs archives created before these modes were
enforced. Normal boots do not recursively rescan historical results.

## Audit trail

`/var/lib/agents/tasks/log` records SUBMIT, DISPATCH, ESCALATE, STEER/STEERED,
ANSWER/ANSWERED, CANCEL/CANCELLED, NOTE, DONE, FAILED, STALLED, CAP, OVERSIZE, and rejection
events. Front-matter values are
sanitised to one token so prompts cannot forge log fields.

The log is an operational narrative, not tamper-evident evidence:
`fleet-operator` can append and rewrite it. Move writes behind a root-owned
append helper or external journal if evidentiary integrity becomes a goal.

## Verification

Routine host checks:

```sh
sudo -n -u fleet-operator fleet health
systemctl --failed
systemctl list-units 'microvm@worker-*.service'
systemctl status opencode-web-access-check.timer
sysctl net.ipv4.ip_forward net.ipv6.conf.all.forwarding
```

From a logged-out external client, both of these must redirect to the account's
`cloudflareaccess.com` login domain, never return the OpenCode application:

```sh
curl -I https://ai.su.is/
curl -I https://ai.su.is/session
```

Containment tests from a disposable worker should confirm that arbitrary DNS,
direct internet access, host SSH, and other guests are unreachable while the
configured model API and Nix cache paths work through squid.

## Remaining design work

- Decide whether the web cockpit remains the full-power `max` seat or moves to
  a dedicated non-wheel, non-Nix-trusted account.
- Add executor-qualified, text-only cross-provider guidance.
- Add generic manual retry and richer running-task inspection controls.
- Move Access application/policy state into Terraform if dashboard drift becomes
  operationally unacceptable.
- Add NixOS integration tests for bridge, firewall, credential, exchange, and
  worker lifecycle invariants.
