# fw0 Host Plan — Consolidated Server on Framework Desktop

**Status:** Specification only. Do not build, scaffold, or generate code until explicitly instructed. Implementation proceeds phase by phase (§10) with review gates.

**Audience:** Claude Code, operating inside the existing NixOS monorepo (Dendritic Pattern, flake-based, agenix secrets, Tailscale fleet).

**Hardware:** Framework Desktop — Ryzen AI Max+ 395 (16c/32t Zen 5), 128 GB unified LPDDR5X (non-ECC, soldered), consumer NVMe. Located at home; residential ISP. The user's daily driver moves to a separate 5900X/7900XTX machine; fw0 becomes a headless always-on server.

**Goal:** fw0 is the consolidated everything-server, replacing vs0/vs1 plans and all rented hosting. Roles: (1) public services migrated off Vultr (static websites dylanc.com and su.is, Minecraft, misc — inventory in Phase 0), (2) general homelab services, (3) local LLM inference (large-model host), (4) a self-hosted agentic-coding execution layer: an on-demand fleet of ephemeral, hardware-isolated microVMs in which coding agents run unattended with full permissions inside a declared boundary, delivering work as pushed branches for human PR review.

---

## 1. Design principles (invariants)

1. **Declarative totality.** Every durable property — host config, guest images, pool size, firewall/tunnel policy, secrets provisioning, memory budgets — is an evaluation product of the flake. No imperative state outside declared scratch/persistent volumes.
2. **Isolation by construction.** Guests contain only what is injected. Containment derives first from absence (monorepo and host secrets never present in a guest), second from access control.
3. **Egress is the policy surface.** Inside a guest the agent runs fully permissioned (`--dangerously-skip-permissions` or equivalent); what it can *reach* is constrained by default-deny egress allowlisting. Destination control, not action control.
4. **Zero inbound.** fw0 opens no inbound ports and depends on no port forwarding. Public reachability is provided exclusively by outbound-initiated tunnels (§4). External port scans of the home IP must show nothing attributable to fw0.
5. **Ephemerality by default.** Guest root is tmpfs; scratch volumes are discarded on stop. Exceptions must be explicit: content-addressed caches (§7.3) and the orchestrator data volume (§6).
6. **Human-gated mutation of the cage.** No agent output alters standing environment (guest definitions, tunnel/firewall policy, credentials, host config) without human review: branch protection on the monorepo + manual host rebuilds. Never auto-deploy the host from unreviewed commits.
7. **Agents never manage their own lifecycle.** Spawn/kill authority lives exclusively in host-side dispatch plumbing.
8. **Least credential.** Guests receive per-repo deploy keys or fine-grained PATs and a model-API credential — never primary SSH identities, classic PATs, tailnet keys, or monorepo-capable credentials.
9. **Static memory allocation.** No ballooning/virtio-mem. Memory elasticity is provided at guest-lifecycle granularity via declared operating modes (§8).

## 2. Host layer

- NixOS host `fw0` in the monorepo, following the existing host pattern. Fresh install (disko layout + reinstall, since the machine converts from desktop to server). BIOS: AMD SVM enabled (one-time manual check).
- Tailscale member; **all** administration, dispatch, and internal service access is tailnet-only. No public SSH; sshd binds tailnet addresses.
- Roles (modules): `server-base` (sshd, tailscale, monitoring, backups), `microvm-host` (microvm.nix host: hypervisor, virtiofs store share, tap bridge, `microvm@` templates), `agent-dispatch` (§7), `ingress-tunnels` (§4), `inference` (§8), plus per-service modules (§5).
- Slices: `agents.slice`, `minecraft.slice`, `inference.slice`, `services.slice` with CPUWeight/MemoryMax/IOWeight so no tenant starves another. Interactive host responsiveness is not a concern (headless), but Minecraft tick latency is: give minecraft.slice high CPU weight and pin to two fast cores.
- Storage: mirrored NVMe if the chassis holds two drives (decide Phase 0; single-drive operation is acceptable given the ephemeral-guest state model, but backups become mandatory either way). Dedicated dataset with quota for the agent subsystem (scratch images, session logs, caches); dedicated dataset for model weights.
- Power/uptime: fw0 shares fate with home power and ISP. Configure auto-boot on power restore; UPS optional (Phase 0 decision). Kernel updates = deliberate reboot windows; drain the fleet first (§8 drain mechanism reused).

## 3. Memory budget (128 GB, static)

Fleet mode: 4 workers × 8 GiB (32) + orchestrator 8 + Minecraft 10 + host/services/page cache reserve 16 ≈ 66 GiB committed, ~62 GiB free (page cache + headroom + small resident inference models).
Inference mode (§8): large model claims up to ~80 GB locked; worker pool contracts per the mode table. Budgets are declared in the flake; the dispatcher reads the active mode. Any pool or profile change re-derives this table — never raise N without it.

## 4. Ingress (zero-inbound topology)

- **Websites:** Cloudflare Tunnel (`services.cloudflared`, credential via agenix). Cloudflare terminates TLS (accepted concession for public static content). Tunnel connector may reach only the local reverse proxy backend — enforce with unit-level network restrictions.
- **Admin/dispatch/orchestrator/inference API:** Tailscale only. Works under CGNAT; no action needed.
- **Minecraft:** raw TCP, cannot use Cloudflare Tunnel or Tailscale Funnel. Phase 0 decision, in order of preference: (a) tailnet-only — share the node with the player set; zero public surface, zero cost; (b) $3–5 VPS relay running rathole/frp or WireGuard+DNAT, terminating the public port and forwarding over an outbound tunnel; public attack surface lives on a disposable credential-free VPS. Do not use third-party game-tunnel services.
- Invariant checks (Phase 4 acceptance): external scan of home IP shows no fw0 ports; tunnel connectors can reach only their designated backends; agent bridge unreachable from any tunnel or public path.
- CGNAT/upload-bandwidth check is a Phase 0 item; it affects only option (b) relay latency, not feasibility.

## 5. Public & homelab services

- Static sites behind the host reverse proxy, fed by the Cloudflare tunnel.
- Minecraft in its own container/microVM under `minecraft.slice` (largest unauthenticated surface → own boundary), 10 GiB ceiling, fast-core pinning.
- Remaining Vultr/homelab services enumerated in Phase 0 and ported as declarative modules.
- DNS cutover per site after verification; decommission Vultr after soak.

## 6. Guest layer (agent fleet)

- microvm.nix guests; hypervisor cloud-hypervisor (fallback qemu). Read-only host /nix/store via virtiofs (guest images are evaluations; spawn cost ≈ boot seconds). tmpfs root; per-instance scratch volume at /workspace; writable Nix store overlay for ephemeral `nix build`/`nix shell`.
- Module structure: `modules/agent-vm/base.nix` (agent CLIs — Claude Code, optionally omp; git, gh, ripgrep, build essentials; sshd for dispatch; egress firewall; secrets; log forwarding), `worker-pool.nix` (`mkAgentGuest`, pool generated by mapping over a range — declared ceiling, instances cost nothing while stopped), `projects/*.nix` overlays composing each project's devShell packages (host evaluates; guests receive derivation outputs, never monorepo source).
- Networking: host-only bridge; guests never join the tailnet. Default-deny egress allowlisting model APIs, forge, cache.nixos.org, and required registries. Implementation preference: host-side allowlisting proxy (centralizes audit) > dnsmasq+nftables ipset > static IPs. Document chosen mechanism and its IP-rotation failure mode.
- Secrets per worker class via agenix: one repo-scoped deploy key/fine-grained PAT + model-API credential. Fleet workers default to API-key auth pending the subscription-terms check (Phase 0).
- **Orchestrator VM (persistent guest class):** long-lived Claude Code session in tmux; persistent data volume (queue history, transcripts, plans) — a declared ephemerality exception. Credentials: fine-grained PAT, read + PR-comment only, no merge, no worker deploy keys. Sole fleet write path is the shared task queue; the deterministic host dispatcher validates and executes lifecycle (orchestrator can flood the queue at worst). Access via SSH ProxyJump through fw0 over the tailnet; the orchestrator does not join the tailnet. Its PR comments are triage input, never approval; independent verification (CI, tests, human review) gates merges. Backup policy for its volume is a Phase 0 decision.
- Repo access patterns: one repo per worker class; deploy keys push-restricted to `agent/*` branches (verify forge ruleset support in Phase 0; compensate with protected branches + CI checks if absent). Monorepo work, if ever, uses a dedicated infra class under the same restrictions, merge and deploy remaining human actions (Phase 6, optional).

## 7. Task lifecycle, dispatch, caching

1. Dispatcher (queue directory + systemd path/timer units) selects task + idle slot → `systemctl start microvm@<class>-<n>`.
2. Guest boots seconds later: declared image, fresh scratch, egress firewall live from first packet.
3. Dispatcher SSHes in (host-only net); guest clones target repo with its deploy key; prompt delivered.
4. Agent runs headless (`claude -p ... --dangerously-skip-permissions --output-format json` or `omp -p --mode json`); free mutation within the session (allowed registries, Nix overlay).
5. Deliverable: branch `agent/<task-id>` pushed to the one reachable repo; session JSONL to the audit dataset.
6. `systemctl stop` → total state evaporation; slot returns to pool. Hard per-task `RuntimeMaxSec` prevents wedged agents holding slots.
7. Human PR review; merge is always human.

- Queue format requires explicit acceptance criteria per task (tests/commands that must pass) — specification quality is the binding constraint on unattended success.
- Caching: (a) widen base images with common toolchains (default); (b) host-side binary cache / registry caching proxy when download overhead is observed; (c) persistent per-class cache volumes only for content-addressed caches. Recurring agent-installed tools are promoted by reviewed commit to the guest definition — the only path from session mutation to standing environment.

## 8. Inference & operating modes

- Local LLM serving (llama.cpp/Ollama-class) as a host service under `inference.slice`, API exposed tailnet-only. Small resident models fit fleet mode permanently.
- Large models (≥40 GB) run under a declared **inference mode**: the inference unit `Conflicts=` with the upper worker instances; activation triggers dispatcher drain (mark slots closed → await task completion or timeout → stop guests → start inference). Deactivation reverses. Modes and their memory tables are flake-declared; the dispatcher reads the active mode for slot sizing.
- Weights must be `--mlock`ed (or GTT-allocated via the iGPU) so the model is a committed, schedulable memory tenant — never mmap-floating page cache that silently degrades under guest pressure.
- Optional composition: a worker class whose agent CLI targets the local endpoint, dispatching token-free tasks during inference-mode windows.

## 9. Security model

| Threat | Mitigation |
|---|---|
| Destructive agent actions | Disposable guest; worst case = discarded VM + bad branch. |
| Prompt-injected exfiltration | Egress allowlist; least credential; audit logs. Residual: use-time exposure of granted values — bounded by key scope and nowhere to send loot. |
| Cage self-modification | Absence of monorepo in guests; credential scope; branch protection requiring human review; manual-only rebuilds. All four layers. |
| Guest escape | KVM hardware boundary; current host kernel (regular rebuild cadence — heightened priority since fw0 also serves public tunnels); guests hold no host credentials. Accepted residual. |
| Public-service compromise | Zero inbound on fw0; tunnel connectors scoped to single backends; Minecraft in its own boundary; public surface (relay VPS) is disposable and credential-free. |
| Orchestrator compromise | Queue-only fleet interface with host-side validation; PAT read+comment only; no tailnet membership; ProxyJump access; volume snapshots; PAT revocation as kill switch. |
| Runaway resources | Fixed guest allocations; slices; RuntimeMaxSec; dataset quotas. |
| Home-host loss (power/ISP/disk) | Auto-boot on power restore; deliverables live on the forge (loss window = in-flight tasks only); orchestrator volume + host state backed up off-machine (Phase 0: target = Storage Box, B2, or peer host). |

## 10. Phases (gated; do not proceed past a gate without instruction)

- **Phase 0 — Inventory & decisions.** Vultr service/DNS inventory; Minecraft ingress choice (§4); CGNAT/upload check; egress mechanism; fleet auth (API key vs subscription — verify current Anthropic terms); disk topology (second NVMe?); UPS; backup target; orchestrator volume policy; forge push-restriction verification. Output: decisions appended here.
- **Phase 1 — Host bring-up.** fw0 host definition, disko, fresh install, tailnet join, slices, datasets, zero-inbound baseline. No guests, no tunnels.
- **Phase 2 — Single guest, manual lifecycle.** base.nix + one worker; verify: egress denial (probe disallowed domain), key scope (out-of-scope push fails), state evaporation on stop.
- **Phase 3 — Pool + dispatch.** Generated pool, queue/dispatcher units, timeouts, audit logging; parallel tasks against non-monorepo repos. Acceptance: task file in queue → booted guest → completed run → pushed `agent/*` branch → audit entry → destroyed guest, no human intervention, all §9 verifications passing.
- **Phase 4 — Services & ingress.** Cloudflare Tunnel + sites; Minecraft per chosen option; Vultr migration + DNS cutover + soak; ingress invariant checks (§4); decommission Vultr.
- **Phase 5 — Orchestrator VM.** §6 orchestrator; verify queue validation rejects malformed/out-of-bounds tasks; PAT cannot push/merge protected branches.
- **Phase 6 — Inference modes.** §8 units, drain logic, mode tables; verify drain under load and mlock accounting.
- **Phase 7 (optional) — Infra worker class.**

## 11. Open questions (resolve in Phase 0; no silent defaults)

1. Minecraft: tailnet-only vs relay VPS (player population decides).
2. Egress mechanism: proxy vs dnsmasq+ipset.
3. Fleet auth: API keys (default) vs subscription OAuth (terms check; orchestrator's interactive session is the one plausible subscription fit).
4. Second NVMe / mirror vs single-disk + aggressive backup.
5. Backup target and cadence (host state, orchestrator volume, service data).
6. UPS.
7. omp in base image alongside Claude Code (capability gaps: DAP debugging, browser automation) — yes/no.
8. Relocation contingency (2028–29 move): note only; architecture is host-portable by construction.
