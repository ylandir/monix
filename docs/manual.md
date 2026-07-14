# monix — technical manual

A single-repo, modular NixOS configuration built on the **Dendritic Pattern**
(flake-parts with `*.mod.nix` auto-discovery). It is Linux-only and designed so
that adding a host is a few lines.

Hosts: **fw3** (Framework 13 AMD 7040 running a Hyprland desktop shelled by
DankMaterialShell) and **fw0** (Framework Desktop, Ryzen AI Max+ 395, 128GB —
headless always-on AI server: the agent-fleet microVM host, the user's
persistent cockpit session, Tailscale, and a LiteLLM/Open WebUI gateway that
is declared but disabled until real secrets exist).

## How it fits together

`flake.nix` imports every `*.mod.nix` file in the tree (via
`listFilesRecursive`), so modules are never listed centrally. Each module
registers *aspects* into one of three collections:

- `commonModules` — imported by every host (base system, options, secrets).
- `nixosModules` — the menu of NixOS aspects (ssh, hyprland, tailscale, the AI
  services, ...). All are imported into every host but most are inert until
  enabled.
- `homeModules` — Home Manager aspects applied to the primary user.

Packages follow one convention: a tool that carries configuration gets its own
concern file with package and settings together (`modules/cli/git.mod.nix`,
`modules/cli/ghostty.mod.nix`); config-less tools are grouped in
`modules/packages.mod.nix` as functional bundles; Nix-workflow tools sit with the
Nix concern in `modules/core/nix.mod.nix`. There is no separate `home/` directory —
a concern file registers its Home Manager aspect directly, and may also register a
NixOS aspect (as `desktop/hyprland.mod.nix` does for the compositor and the
session).

The folders under `modules/` are namespacing only (discovery is by the
`.mod.nix` suffix, not location): `core/` is the every-host base layer,
`cli/` terminal tools, `desktop/` the graphical session, `networking/` and
`server/` what their names say. `packages.mod.nix` sits at the root because
its bundles span categories.

`lib/` extends nixpkgs' lib under its own namespace. `lib.monix.nixosSystem
"<name>" <module>` defines `nixosConfigurations.<name>`.

A host (`hosts/<name>/<name>.mod.nix`) just imports the collections, sets its
class and hardware, and enables the services it wants:

```nix
imports =
  attrValues self.commonModules
  ++ attrValues self.nixosModules;

isDesktop = true;            # or false for a server
nixpkgs.hostPlatform = "x86_64-linux";
disko.devices.disk.main = { ... };   # declarative disk layout (see disko.mod.nix)
system.stateVersion = "26.05";
```

There is no `hardware-configuration.nix`: the host module carries the few
per-machine hardware facts (initrd kernel modules, microcode) directly, and
the disk layout is declared with disko, which both generates the mount config
and can format a blank disk to match.

### Desktop vs server

The single switch is `isDesktop` (default `false` ⇒ server). Desktop aspects
(Hyprland, audio, fonts, NetworkManager, the user's graphical session) gate on
it with `mkIf config.isDesktop`, so a server simply omits them by leaving the
flag false. Service aspects (LiteLLM, Open WebUI, Tailscale) gate on their own
`enable` option, which the host turns on.

## Adding a host

1. `mkdir hosts/<name>` and create `hosts/<name>/<name>.mod.nix` (copy fw3 or
   fw0). Set `isDesktop`, `nixpkgs.hostPlatform`, `system.stateVersion`.
2. Set the hardware facts and disko layout in the host module (crib the
   kernel-module list from `nixos-generate-config --show-hardware-config` on
   the machine; point `disko.devices.disk.main.device` at the disk's
   `/dev/disk/by-id/...` path).
3. Add the host's SSH host public key to `keys.nix` under `hosts.<name>`.
4. Add the host's secret rules to `secrets.nix` and create the secrets.
5. Build: `nixos-rebuild switch --flake .#<name>`.

No other file needs editing — auto-discovery and the aspect collections handle
the rest.

## Secrets (agenix)

agenix manages fw0's fleet subscription credentials, optional provider keys,
and Cloudflare Tunnel token. Login passwords remain imperative. The disabled
LiteLLM/Open WebUI examples still have placeholder secret files and must not be
enabled until those specific files are replaced with real age ciphertext.

`keys.nix` is the single source of truth for SSH public keys (host keys + admin
keys). `secrets.nix` maps each secret file to the keys it is encrypted to and is
read by the `agenix` CLI. Secrets are decrypted on the host using its SSH host
key (`/etc/ssh/ssh_host_ed25519_key`).

**Bootstrap (per host):**

1. On the target machine, ensure host keys exist: `ssh-keygen -A`.
2. Copy its public key into `keys.nix`:
   `cat /etc/ssh/ssh_host_ed25519_key.pub`.
3. Put your personal public key in `keys.nix` under `admin`.
4. Create the needed secrets (an entry must already exist in `secrets.nix`):

   ```sh
    agenix -e hosts/fw0/agent-claude-token.age
    agenix -e hosts/fw0/agent-codex-auth.age
    agenix -e hosts/fw0/opencode-web-cloudflare-tunnel-token.age
   ```

`tailscale.age` holds a one-line reusable auth key (`tskey-auth-...`).

> Users are mutable (the NixOS default) — after install, set each account's
> login password imperatively with `passwd`. Login never depends on agenix,
> so a host can be built and activated with no secrets present at all.

## The agent fleet on fw0

fw0 hosts an eight-worker warm pool of disposable microVMs in which Claude Code,
Codex, or opencode runs one fully-permissioned task. Workers are contained by
KVM, a host-only isolated bridge, no gateway/DNS, a default-deny squid egress
proxy, executor-specific Unix credentials, bounded host-file exchange, and
fleet-wide resource limits. Each guest boots a sealed read-only erofs image of
its own closure rather than sharing the host's live store, so host store
maintenance (gc/optimise) cannot touch a running worker. They have no forge
access: the cockpit supplies a source capsule and receives a report plus patch.
The primary cockpit is available through tmux/SSH and at `ai.su.is` through
Cloudflare Access. See [agent-fleet.md](agent-fleet.md) for mechanics and trust
boundaries.

How a task moves through the system, end to end:

![fleet task flow](img/fleet-flow-1.svg)

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

The full decision tree — dispatch routing, the worker VM lifecycle with all
failure paths, every mid-task interaction (live peek, steering, escalation
with three advisor backends), and the results flow — is in
[fleet-flow.md](fleet-flow.md).

## The AI stack on fw0

Declared in `hosts/fw0/fw0.mod.nix` but currently commented out (the `.age`
secret files are placeholders — see the warning above). When enabled:

- **LiteLLM** runs on `127.0.0.1:4000` as an OpenAI-compatible gateway. Its
  `model_list` (in `hosts/fw0/fw0.mod.nix`) is illustrative — edit it for your
  providers. `os.environ/NAME` reads NAME from `litellm.env.age`, which must
  define `LITELLM_MASTER_KEY` and every referenced provider key, e.g.:

  ```sh
  LITELLM_MASTER_KEY=sk-...generate-a-strong-key...
  OPENAI_API_KEY=sk-...your-openai-key...
  ANTHROPIC_API_KEY=sk-ant-...your-anthropic-key...
  ```

- **Open WebUI** runs on `0.0.0.0:8080` and uses LiteLLM as its backend
  (`OPENAI_API_BASE_URL=http://127.0.0.1:4000/v1`). `open-webui.env.age` must
  set `OPENAI_API_KEY` to the **same value** as LiteLLM's `LITELLM_MASTER_KEY`
  (this is how Open WebUI authenticates to LiteLLM), plus a `WEBUI_SECRET_KEY`:

  ```sh
  OPENAI_API_KEY=sk-...same-as-LITELLM_MASTER_KEY...
  WEBUI_SECRET_KEY=...generate-a-strong-key...
  ```

Neither service opens the public firewall. They are reachable over **Tailscale**
(the `tailscale0` interface is trusted) and via localhost. Reach Open WebUI at
`http://<fw0-tailscale-ip>:8080`.

## Building

```sh
nix flake check                          # evaluate everything
nixos-rebuild switch --flake .#fw3       # or .#fw0
```

First install of a host, from any NixOS installer ISO (formats the disk
declared in the host's disko layout — destructive, check the device path):

```sh
sudo nix run github:nix-community/disko -- --mode disko --flake .#<host>
sudo nixos-install --flake .#<host>
```

## Design choices (deliberate)

- **Linux-only** — no darwin/macOS support.
- **`isDesktop` flag** with `mkIf` gating rather than per-host aspect menus —
  every aspect is imported everywhere and gates itself.
- **Home Manager** for the user session (best Hyprland support), organised as
  `homeModules` aspects.
- **No hardware-configuration.nix / nixos-facter** — per-host hardware facts
  live directly in the host module; disk layouts are declared with disko.
- **Explicit `secrets.nix` rules** (so `agenix -e` works when first creating a
  secret); agenix identity is the system SSH host key rather than a separate
  key partition.
- **No pipe operators** — see AGENTS.md.

## The desktop (fw3)

- **Hyprland config is written in Lua** (`configType = "lua"`), not hyprlang.
  Hyprland deprecated hyprlang at 0.55 (nixpkgs currently ships 0.55.4) in
  favor of Lua, with hyprlang stated to be dropped "1-2 releases" after 0.55.
  Binds are built with a small `mkBind`/`mkEnv` helper in
  `modules/desktop/hyprland.mod.nix`; each bind carries a `description`,
  read back at runtime via `hyprctl binds -j` to power the DMS keybinds
  overlay (SUPER+K) — a `.lua` config is executed, not parseable, so the
  live bind list is the only reliable source.
- **Hyprland is pulled from nixpkgs**, not a git flake input. The session is
  managed by UWSM (greetd → `uwsm start` → Hyprland; see the session-entry
  comment in `hyprland.mod.nix`).
- The desktop shell is **DankMaterialShell** (DMS): the bar, notifications,
  app launcher (spotlight), OSD, control center, lock screen with idle
  handling, wallpaper manager, clipboard history UI, and polkit agent all
  come from it (`modules/desktop/dank.mod.nix`, `programs.dms-shell` from
  nixpkgs; the `dank-material-shell` flake input supplies the greetd greeter
  and a newer shell build — see the comments there).
- **Theming:** DMS's dynamic (wallpaper-synced) theming is enabled for
  GTK/Qt apps via matugen + adw-gtk3 + qt5ct/qt6ct; other apps (ghostty,
  btop, Hyprland borders) use their default themes. CaskaydiaMono Nerd Font
  is the desktop's default monospace font.
