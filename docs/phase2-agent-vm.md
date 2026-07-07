# Phase 2 — Single agent guest, manual lifecycle

**Status:** Plan. Implements Phase 2 of [agent-host-plan.md](./agent-host-plan.md) (§10),
within the reduced scope (AI-server roles only; no websites/Minecraft) and with the
cockpit addendum (the user's primary session lives on fw0 and is the "dispatcher" for
this phase — no queue/dispatcher units until Phase 3).

**Goal:** one worker microVM on fw0, started and stopped by hand, in which Claude Code
runs fully-permissioned against exactly one repo (`cdland/lfish`), contained by
default-deny egress. Exit gate: all six verifications in §7 pass.

**Pre-flight already verified on fw0:** `/dev/kvm` present (SVM enabled), 125GB RAM,
`@agents` dataset mounted at `/var/lib/agents`, `agents.slice` declared (48G ceiling).

---

## 1. Decisions locked by this plan

| Decision | Choice | Rationale |
|---|---|---|
| Hypervisor | `cloud-hypervisor` (qemu fallback) | Plan §6 preference; virtiofs supported (9p is not — irrelevant, we use virtiofs). |
| Egress mechanism (master-plan open question #2) | **Host-side allowlisting proxy (squid)** on the bridge IP; guests get no DNS, no NAT, no default route | Default-deny becomes structural: the only route out of a guest is CONNECT through squid, which enforces a `dstdomain` allowlist and produces a per-request audit log. Beats dnsmasq+ipset (IP-rotation fragility) per the master plan's own preference order. |
| Fleet auth (open question #3) | API key (`ANTHROPIC_API_KEY`) via agenix on host, injected per §5 | Master-plan default pending subscription-terms check. |
| Memory | `microvm.mem = 8192` (MiB), `balloon = false` (module default) | Plan invariant 9: static allocation, no ballooning. |
| vCPU | `microvm.vcpu = 8` | 16c/32t host; 4 workers × 8 vCPU overcommits threads 1:1 at full fleet, acceptable for bursty agent workloads under equal CPUWeight. |
| Worker repo binding | Worker class `lfish` → `github.com/cdland/lfish`, deploy key push-restricted to `agent/*` | Least credential; one repo per class (plan §6). |
| Ephemerality | Read-only erofs root + **scratch/overlay volume images deleted before every start** | Corrected from master plan: microvm.nix guest root is a read-only erofs/squashfs store disk, **not** tmpfs, and volumes persist under `/var/lib/microvms/<name>/` by default. Evaporation must be explicit: an `ExecStartPre` wipe of the volume images (they auto-recreate via `autoCreate`). §7f verifies. |

## 2. Flake changes

```nix
inputs.microvm = {
  url = "github:microvm-nix/microvm.nix";
  inputs.nixpkgs.follows = "nixpkgs";
};
```

## 3. Host side — `modules/server/microvm-host.mod.nix`

New aspect `flake.nixosModules.microvm-host`, self-gated on a new option
`agentFleet.enable` (defined in this module, mkEnableOption; fw0 sets it true).
Contents, all under the gate:

1. **Import** `inputs.microvm.nixosModules.host` (host runner: `microvm@` templates,
   virtiofsd units, `/var/lib/microvms` state dir). Set
   `microvm.stateDir = "/var/lib/agents/microvms"` so guest state lands on the
   `@agents` dataset.
2. **Bridge** `br-agents`, host-only, via systemd-networkd:
   - netdev `br-agents` (bridge), address `10.100.0.1/24`, no uplink port ever attached.
   - `matchConfig.Name = "vm-*"` → Bridge=br-agents (TAP interfaces enslaved by name).
   - **No NAT, no IP forwarding for this bridge.** There is nothing to route to.
   - Note: fw0 currently uses DHCP via the default networking scripts;
     enabling systemd-networkd for the bridge must not break eth DHCP —
     use `systemd.network` only for `br-agents`/`vm-*` and keep
     `networking.useDHCP` for the uplink (verify both after deploy; this is
     the riskiest edit in the phase — do it with console access available or
     accept a power-cycle recovery).
3. **nftables policy** (composes with the existing firewall):
   - input from `br-agents`: allow TCP 3128 (squid) only; drop everything else
     (including DNS/53 and the host's sshd — the trustedInterfaces list must NOT
     include br-agents).
   - forward involving `br-agents`: drop (belt over the no-forwarding suspenders).
4. **Squid** bound to `10.100.0.1:3128`:
   - `acl allowed dstdomain` from a nix list (one place to edit):
     `api.anthropic.com`, `statsig.anthropic.com`, `sentry.io` (Claude Code telemetry,
     optional — decide at impl), `github.com`, `codeload.github.com`,
     `objects.githubusercontent.com`, `cache.nixos.org`, `channels.nixos.org`.
   - `http_access allow CONNECT allowed`; deny all else; access log on (this IS the
     egress audit trail, plan §9).
   - Squid does the DNS resolving; guests never resolve anything themselves.
5. **Slice**: `systemd.services."microvm@lfish-0".serviceConfig.Slice = "agents.slice"`
   (microvm.nix has no slice option; standard unit override, one line per declared VM —
   generated from the same list as the VM declarations).
6. **Ephemerality hook**: `systemd.services."microvm@lfish-0".serviceConfig.ExecStartPre`
   removes `<stateDir>/lfish-0/*.img` so scratch + store-overlay images are recreated
   blank on every start.

## 4. Guest profile — `modules/server/agent-vm/base.mod.nix`

Exposed as `flake.lib`-style helper or a plain module set used by `microvm.vms`
declarations (NOT part of `self.nixosModules` — guests are not fleet hosts and must not
import the host aspect collections; they get a minimal, purpose-built module list).
`mkAgentGuest { name, repo, extraModules }` returns a `microvm.vms.<name>` value:

- `config.microvm`: hypervisor cloud-hypervisor; vcpu/mem per §1; interfaces
  `[{ type = "tap"; id = "vm-<name>"; mac = <derived, 02:xx locally-administered>; }]`;
  shares `[{ proto = "virtiofs"; tag = "ro-store"; source = "/nix/store";
  mountPoint = "/nix/.ro-store"; }]`; `writableStoreOverlay = "/nix/.rw-store"` backed
  by a volume (`nix-overlay.img`, 8192 MiB); scratch volume `workspace.img`
  (20480 MiB) at `/workspace`.
- **Networking (guest):** static `10.100.0.11/24` on its NIC, **no default gateway, no
  DNS servers**. Global proxy env: `HTTPS_PROXY=http://10.100.0.1:3128`,
  `HTTP_PROXY=...`, `NO_PROXY=""` in `environment.variables` (+ `environment.sessionVariables`).
  Claude Code, git-over-https and nix all honor these.
- **Packages:** claude-code, git, gh, ripgrep, fd, jq, coreutils/build essentials
  (gcc, gnumake), plus whatever `extraModules` (per-project devShell packages) add.
  Nix inside the guest configured with the same substituters + experimental-features
  (works via proxy).
- **sshd:** enabled, `PermitRootLogin prohibit-password` on the bridge address only;
  authorized key for the `agent` user = the **admin keys** for Phase 2 (the human is
  the dispatcher; a dedicated dispatch keypair arrives with Phase 3's dispatcher).
- **Users:** single `agent` user (wheel-less, but full sudo-less ownership of
  /workspace); no other accounts.
- **Repo access:** git configured with `url."git@github.com:cdland/lfish".insteadOf`?
  No — SSH to github.com is blocked by the proxy model (CONNECT to port 443 only).
  Use **HTTPS + fine-grained PAT** scoped to `lfish` (contents: read/write) instead of
  an SSH deploy key: SSH-over-443 complicates the egress story, and a fine-grained PAT
  gives the same per-repo containment with plain HTTPS. Stored as a git credential via
  the secret in §5. (Deviation from master plan's "deploy key" wording, same
  containment class; branch restriction enforced server-side by a GitHub ruleset, §6.)
- **No tailnet, no monorepo, no host secrets** — by absence (nothing injects them).

## 5. Secrets path

- New agenix secrets (rules in `secrets.nix`, encrypted to fw0 + admin):
  - `hosts/fw0/agent-anthropic.age` — `ANTHROPIC_API_KEY=...` env format.
  - `hosts/fw0/agent-lfish-pat.age` — the fine-grained PAT for `cdland/lfish`.
- Injection: `microvm.credentialFiles = { "anthropic" = <agenix path>; "repo-pat" = ... }`
  (systemd credentials, surfaced inside the guest under the credentials directory).
  A tiny guest oneshot copies them into `agent`'s environment
  (`/run/agent-env`, mode 0400, sourced by the shell profile).
  **Fallback if credentialFiles proves awkward with cloud-hypervisor:** a second
  virtiofs share of a host directory containing only that worker class's two files.
  Decide during implementation; the acceptance tests don't care which.

## 6. GitHub side (user actions, one-time)

1. Create a **fine-grained PAT** restricted to `cdland/lfish`, permissions:
   Contents read+write. Nothing else.
2. Add a **ruleset** on `lfish`: protect `main` (and any release branches) from the
   PAT's pushes — restrict pushes to `main`, allow branch creation matching `agent/**`.
   This is the master plan's "verify forge push-restriction support" item: if rulesets
   can't express it cleanly, fall back to plain branch protection on `main` (agent can
   push other branches, cannot touch main) — acceptable for Phase 2.
3. Hand both secret values over for `agenix -e` (or run the two `agenix -e` commands
   yourself on any machine with an admin key).

## 7. Verification protocol (exit gate — all must pass, run from the cockpit)

| # | Check | Command sketch | Pass condition |
|---|---|---|---|
| a | Boot cost | `time systemctl start microvm@lfish-0` | Interactive-tolerable (target: seconds, <30s hard) |
| b | Egress deny | In guest: `curl -m5 https://example.com`; `getent hosts google.com`; `curl -m5 http://10.100.0.1:22` | All fail: proxy 403 for non-allowlisted domain, no DNS, no host ports besides 3128 |
| c | Egress allow | In guest: `curl -sI https://api.anthropic.com`, `git ls-remote https://github.com/cdland/lfish` | Succeed via proxy; squid access.log shows both |
| d | Agent runs | In guest: `claude -p 'reply OK' --dangerously-skip-permissions` | Returns; API reached through proxy |
| e | Key scope | In guest: clone lfish, push `agent/phase2-test`; then attempt push to `main` | First succeeds, second rejected by forge |
| f | Evaporation | Touch files in `/workspace` and `/root`, `nix build` something trivial (populates rw overlay), stop VM, start VM | All artifacts gone; overlay + scratch images recreated blank |
| g | Host isolation | From guest: attempt `ssh 10.100.0.1`, curl fw0's tailscale IP, read /nix/store write-ability | ssh refused/filtered; tailscale IP unreachable; store read-only |

Also record: `systemd-cgls /agents.slice` shows the VM under the slice; host memory
accounting sane.

## 8. Sequencing (each step gates the next)

1. Flake input + `microvm-host.mod.nix` skeleton (bridge + nftables + squid, no VM yet).
   Deploy. Verify from host: bridge up, squid answering on 10.100.0.1:3128, fw3→fw0
   tailnet ssh unaffected, uplink DHCP unaffected.
2. Guest profile + `microvm.vms.lfish-0` declaration with **secrets stubbed**
   (empty env). Build toplevel on fw3 (cross-check eval), deploy, start VM manually.
   Verify a, b, g and console access (`machinectl`/ssh from host).
3. User completes §6 (PAT + ruleset), secrets created with `agenix -e`. Redeploy.
   Verify c, d, e.
4. Ephemerality hook + verification f.
5. Mark Phase 2 done in this doc; record measured boot time + any deviations.
   Update master plan §10 gate status.

## 9. Risks / watch items

- **systemd-networkd + script-based DHCP coexistence** on fw0 (step 1) — the only
  change with lockout potential; mitigated by console access and by touching only
  `br-agents`/`vm-*` matches.
- **cloud-hypervisor on Strix Halo** — young silicon; if flaky, `microvm.hypervisor =
  "qemu"` is a one-line fallback (both support virtiofs).
- **credentialFiles ergonomics** under cloud-hypervisor (§5 fallback ready).
- **virtiofs ro-store staleness**: host `nix-collect-garbage` while a guest runs could
  remove paths a guest still references. Do not run GC with the fleet up (later: GC
  roots per declared VM — microvm.nix's declarative VMs are host closure roots, which
  covers the base image; the rw-overlay contents are disposable by design).
- **Proxy blind spots**: anything speaking non-HTTP(S) (ssh git, raw model gRPC) simply
  fails closed. That's the intended posture; expand the allowlist deliberately, never
  bypass the proxy.

## 10. Explicitly deferred (Phase 3+)

Queue directory + dispatcher path/timer units, `RuntimeMaxSec` per task, pool
generation (`mkAgentGuest` mapped over a range), audit-log dataset shipping, dedicated
dispatch keypair, orchestrator VM, inference modes and drain.
