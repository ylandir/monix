# The life of a task — fleet decision tree

How work moves through the ship: every box a task can visit, every decision
that routes it, and every way it can come back. Companion to
[agent-fleet.md](agent-fleet.md) (mechanics and trust boundaries); this
document is the map.

Roles: the **captain** (human) commands; the **cockpit** (engineer model —
Claude Code seat or opencode web seat, same authority) runs the ship; the
**drones** (disposable worker microVMs) each execute exactly one task.

## 1. The big picture

![fleet flow diagram 1](img/fleet-flow-1.svg)

<details><summary>Diagram source (Mermaid)</summary>

```mermaid
flowchart TD
    CAP([Captain states a goal]) --> CKPT{"Cockpit:<br/>how to do this?"}

    CKPT -->|"clarify / decision only the<br/>captain can make (taste, scope,<br/>destructive, push, switch)"| ASK[Ask the captain] --> CAP
    CKPT -->|"small, local, or depends on<br/>unpushed/private host state"| LOCAL[Do it in the cockpit session]
    CKPT -->|substantial + self-contained| PLAN["Write task file:<br/>choose agent + model + effort<br/>+ guidance per task"]

    PLAN --> DISPATCH[fleet dispatch / submit<br/>via scoped sudo → queue]
    DISPATCH --> DRONE[Drone runs the task<br/>in a warm microVM]

    DRONE <-->|"peek / steer /<br/>escalate / answer"| MID[Mid-task interaction<br/>with the cockpit]
    DRONE --> RESULT["Archive: report, log, patch,<br/>usage, progress, messages, Q&A"]

    RESULT --> REVIEW{Cockpit reviews<br/>UNTRUSTED output}
    REVIEW -->|inadequate / failed| PLAN
    REVIEW -->|"needs a stronger model<br/>or different provider"| PLAN
    REVIEW -->|good| APPLY[Apply patch, verify,<br/>commit locally]

    LOCAL --> VERIFY["Verify: build / test / run"]
    APPLY --> VERIFY
    VERIFY --> REPORT([Report up to the captain])
    REPORT -->|push? switch? next heading?| CAP
```

</details>

Authority flows one way — captain → cockpit → drones — and every upward
arrow is *information*, never command: drone output is untrusted data, and
the cockpit acts on it only with its own judgment.

## 2. Dispatch: the cockpit's routing decisions

The cockpit is the sole decider. A task file **must** name `agent` and
`model` (missing either → rejected at submit, exit 2, nothing enqueued —
no downstream defaults exist).

![fleet flow diagram 2](img/fleet-flow-2.svg)

<details><summary>Diagram source (Mermaid)</summary>

```mermaid
flowchart TD
    TASK[Task in hand] --> WHERE{Where should it run?}

    WHERE -->|"needs session context,<br/>real judgment, or private state"| COCKPIT[Cockpit does it itself]
    WHERE -->|self-contained work| EXEC{Pick executor + model<br/>by the economics doctrine}

    EXEC -->|"mechanical, fully specified"| HAIKU[claude / haiku]
    EXEC -->|"routine impl from clear spec"| SONNET[claude / sonnet]
    EXEC -->|"substantial standalone coding,<br/>independent second opinion<br/>(ChatGPT pool)"| SOL[codex / gpt-5.6-sol]
    EXEC -->|"anything on the OpenRouter<br/>catalog (per-token billing)"| OR[opencode / openrouter/…]
    EXEC -->|"bulk low-stakes volume<br/>(free, weaker, on-GPU)"| LOCALM[opencode / local/…]
    EXEC -->|"frontier judgment inside<br/>the Claude pool"| FABLE[claude / fable]

    HAIKU & SONNET & SOL & OR & LOCALM & FABLE --> GUID{Escalation channel?}
    GUID -->|"omitted (the default)"| G0["no channel —<br/>escalations answered instantly<br/>'use your own judgment';<br/>a blocked drone reports<br/>what's missing and exits"]
    GUID -->|"the live cockpit"| G2["guidance: cockpit —<br/>questions surface to the engineer"]

    G0 & G2 --> CTX{Does it need source context?}
    CTX -->|yes| CAPSULE["fleet dispatch &lt;slug&gt; task.md &lt;dir&gt;<br/>→ capsule (prompt ≤1 MiB + context<br/>≤512 MiB compressed, .git/.env excluded)"]
    CTX -->|"no (prompt is self-sufficient)"| SUBMIT["fleet submit &lt;slug&gt; < task.md"]

    CAPSULE & SUBMIT --> Q[(Queue<br/>operator-owned)]
```

</details>

Fan-out is free: submit N tasks and up to 10 warm drones run them
concurrently; the same review can be sent to two vendors in parallel for
genuinely independent opinions.

## 3. Inside the drone: one task, one VM, one life

![fleet flow diagram 3](img/fleet-flow-3.svg)

<details><summary>Diagram source (Mermaid)</summary>

```mermaid
flowchart TD
    WARM(["Warm pool: idle VM,<br/>guest refreshes .ready<br/>every second"]) -->|"idle > 2h<br/>(preventive)"| RECYCLE
    WARM -->|"VM died or .ready<br/>went stale while idle"| RECYCLE[Destroy + reboot<br/>fresh warm VM] --> WARM

    Q[(Queue)] --> CLAIM["Rust drainer atomically claims task<br/>(one resident root drainer per worker)"]
    WARM --> CLAIM
    CLAIM --> ALIVE{"VM alive and .ready<br/>FRESH (≤60s)?"}
    ALIVE -->|no| REQ1[Requeue task] --> Q
    ALIVE -->|yes| STAGE["Stage EXACTLY the selected<br/>executor's credential + task-meta<br/>(local/ tasks get none)"]
    STAGE --> DELIVER["Deliver context, then prompt.md LAST<br/>→ DISPATCH in audit log"]

    DELIVER --> GUEST{"Guest validates:<br/>credential set matches executor?<br/>capsule extracts cleanly?"}
    GUEST -->|"no → exit 64/65/66,<br/>executor never launches"| FAIL
    GUEST -->|yes| RUN["Executor CLI runs unsandboxed<br/>(all actions auto-approved) as its<br/>non-root executor user — containment<br/>is the host: no route, no DNS, no<br/>GitHub; squid allowlist for egress,<br/>direct bridge HTTP for local/ inference"]

    RUN --> WATCH{Host watchdogs}
    WATCH -->|"exit-code written"| DONE{exit 0?}
    WATCH -->|"no heartbeat 120s,<br/>but NONE ever arrived<br/>(never picked up)"| REQ2["Pool fault, not task fault:<br/>requeue ONCE on the fresh VM<br/>the recycle produces"] --> Q
    WATCH -->|"no heartbeat 120s<br/>(after pickup, or 2nd time)"| STALL[STALLED] --> FAIL
    WATCH -->|"6h absolute cap"| CAP2[CAP] --> FAIL
    WATCH -->|"exchange > 768 MiB"| OVER[OVERSIZE] --> FAIL

    DONE -->|yes| OK[→ done/]
    DONE -->|no| FAIL[→ failed/]

    OK & FAIL --> STOPVM["VM stopped,<br/>credentials cleared"]
    STOPVM --> ARCHIVE["Bounded no-follow archival:<br/>prompt, exit-code, report ≤10 MiB,<br/>log + patch ≤50 MiB, usage ≤64 KiB,<br/>progress, messages, Q&A"]
    ARCHIVE --> WIPE["Volumes wiped on next VM start<br/>→ fresh warm guest boots"]
    WIPE --> WARM
```

</details>

The VM is destroyed after every task regardless of outcome — a compromised
or wedged drone is one recycle from pristine, and nothing an agent writes
survives except the bounded archive. A drainer that restarts mid-task
(host switch, crash) requeues whatever was stranded in `running/`.

## 4. Mid-task: every way the cockpit and a running drone interact

![fleet flow diagram 4](img/fleet-flow-4.svg)

<details><summary>Diagram source (Mermaid)</summary>

```mermaid
flowchart TD
    subgraph DRONE_VM [Running drone]
        AGENT[Agent working]
        AGENT -->|"writes progress.md<br/>at each major step"| PROG[progress.md]
        AGENT -->|"checks ls /run/task at<br/>checkpoints + before report"| MSGS[message-N.md]
        AGENT -->|"genuine judgment call:<br/>ask-cockpit '…' (max 5)"| QN[question-N.md]
    end

    PROG -->|"drainer mirrors on change<br/>(progress ≤1 MiB, log tail 64 KiB,<br/>bounded no-follow)"| LIVE[(live/&lt;id&gt;/<br/>host-owned mirrors)]
    LIVE -->|"fleet peek &lt;id&gt;<br/>progress + questions + log tail"| ENG

    ENG[Cockpit engineer] -->|"fleet steer &lt;id&gt; 'msg'<br/>(≤32 per task, ≤64 KiB each)"| SPOOL[(steer spool)]
    SPOOL -->|"drainer delivers<br/>→ STEERED"| MSGS

    QN -->|"≤64 KiB each"| WHO{Task's guidance setting}
    WHO -->|"anything but cockpit"| AUTO["Instant answer:<br/>'use your own judgment'"] --> ANS
    WHO -->|cockpit| ATTN["fleet health: questions-pending<br/>+ ATTENTION line; visible in peek"] --> ENG
    ENG -->|"fleet answer &lt;id&gt; &lt;n&gt;<br/>(may consult the captain first)"| ANS[answer-N.md ≤1 MiB<br/>delivered into the guest]
    ANS -->|"agent unblocks (waits<br/>up to 30 min, then proceeds<br/>on its own judgment)"| AGENT

    ENG -.->|"wedged vs thinking?<br/>peek first, then judgment:<br/>let it run / steer / kill"| DRONE_VM
```

</details>

Two invariants hold everywhere in this diagram: the host **displays**
guest-written content and **delivers** cockpit-written files, but never
takes instructions from guest prose. The host acts only on narrow machine
fields it defined itself: `exit-code` for task routing and the root-produced
`usage.json` for the cost ledger. Both are bounded and format-checked. Everything crossing the boundary is a bounded
regular file moved with no-follow semantics.

## 5. Results: from archive to the captain

![fleet flow diagram 5](img/fleet-flow-5.svg)

<details><summary>Diagram source (Mermaid)</summary>

```mermaid
flowchart TD
    DONE[(done/ or failed/)] --> FETCH["fleet fetch &lt;id&gt; — report wrapped<br/>in UNTRUSTED banner; fleet logs /<br/>fleet patch for transcript + diff"]
    FETCH --> JUDGE{Engineer's review}

    JUDGE -->|"failed or inadequate"| RETRY{Why?}
    RETRY -->|"model below the task's bar"| UP["Escalate a tier and<br/>redispatch — never retry<br/>at the same tier"]
    RETRY -->|"directive was ambiguous"| REWRITE[Rewrite the task file,<br/>redispatch]
    UP & REWRITE --> BACK([→ dispatch tree, §2])

    JUDGE -->|"report suggests follow-up work"| OWN["Engineer's OWN judgment decides —<br/>never auto-dispatch a drone's<br/>suggestion; consequential calls<br/>go to the captain"]
    JUDGE -->|good| PATCH{Code change?}

    PATCH -->|yes| APPLY["fleet patch &lt;id&gt; → apply to the<br/>real repo, verify (build/test/run),<br/>commit — plain message, NO push"]
    PATCH -->|"no (research/report)"| SUMM[Summarize up]

    APPLY & SUMM & OWN --> CAPREPORT([Report to captain with evidence])
    CAPREPORT --> CAPDECIDE{Captain}
    CAPDECIDE -->|push| PUSH[git push]
    CAPDECIDE -->|activate| SWITCH[nh os switch .#fw0<br/>captain-only]
    CAPDECIDE -->|new heading| NEXT([Next task → §1])
```

</details>

## 6. The full audit trail

Every **state-changing** hop leaves a line in `/var/lib/agents/tasks/log`
(read-only commands — watch, fetch, logs, patch, peek — do not):

```
SUBMIT → DISPATCH → [STEER → STEERED]*
                  → [CANCEL → CANCELLED]?
                  → [ESCALATE (→ ANSWER → ANSWERED, cockpit guidance only)]*
                  → DONE | TIMEOUT (after a STALLED / CAP / OVERSIZE line)
```

A pre-pickup stall instead logs a requeue and later a second `DISPATCH`.
Add `NOTE` for free-text cockpit
annotations and rejection lines for anything that failed a trust check.
`fleet status` tails the log; `ship-status` shows the live pool;
`ship-costs` attributes each task's tokens to its subscription pool.
