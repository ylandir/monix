# fw3 state & determinism audit — 2026-07-12

Scope: worked backwards from the repo (no changes made on fw3). Items that can
only be observed on the host are listed as a runnable checklist below.

## Fixes applied in this pass (repo)

| Change | File | Status |
|---|---|---|
| ghostty activation hook: drop `+validate-config` (SIGUSR2 race, exit 140), replace with non-fatal `systemctl --user try-reload-or-restart` | `modules/ghostty.mod.nix` | verified: built HM activation package, hook is the reload only |
| Mask `xdg-document-portal.service` (ships inside `xdg-desktop-portal`, fails on missing `fusermount3`; flatpak was never enabled and is not installed) | `modules/desktop/hyprland.mod.nix` | verified: unit `enable = false` evals; mask symlink generated at build |
| Bound the journal: `SystemMaxUse=1G` | `modules/journald.mod.nix` (new) | verified by eval |
| fw3 host key filled in (was a placeholder — agenix could not encrypt anything to fw3 at all) | `keys.nix` | key taken from fw3's SSH host key (TOFU over tailnet) — confirm against `cat /etc/ssh/ssh_host_ed25519_key.pub` on fw3 |
| agenix rule for the login password secret | `secrets.nix` (`hosts/fw3/dylan-password.age`) | rule only; ciphertext not yet created |
| `users.mutableUsers = false` + `hashedPasswordFile` wiring | `hosts/fw3/fw3.mod.nix` | **commented out** — see gate below |

## Gate: declarative users (do this before uncommenting)

With `mutableUsers = false` and no declared password the account is locked out
(wheel sudo needs a password; SSH keys don't help). Enable only after:

```
mkpasswd -m yescrypt                          # copy the hash
cd ~/ark/monix && agenix -e hosts/fw3/dylan-password.age   # paste hash, save
# then uncomment the block in hosts/fw3/fw3.mod.nix (add `config` to its args),
# build, switch, and verify `sudo -v` from a second session before logging out.
```

fw0 note: when `users.mod.nix` hosts eventually all go immutable, fw0 needs the
same treatment for its user first.

## Build gate (pre-existing, unrelated to these changes)

The committed lock's nixpkgs (`nixpkgs_3` = `0bb7ec5`) has a broken
`click-threading` (pytest collects `docs/conf.py`, `pkg_resources` gone on
py3.14) → `vdirsyncer` → `khal` → `system-path`, so **no system-level attr of
fw3 builds**, including `/etc`. fw3's checkout has an uncommitted
`nix flake update` (nixpkgs `e7a3ca8`) that clears it — the running system was
built from that. Decide: commit that lock update (or a fresh `nix flake
update`) so the repo builds again. Until then, verification here is eval-level.

## Known drift between repo and hosts

| Item | Disposition |
|---|---|
| fw3 checkout at `abafa3b` (behind main) with dirty `flake.lock` | investigate — commit or discard; repo should be the only source of truth |
| fw3 cannot `git fetch` from GitHub (publickey denied) | investigate — deploy path to fw3 needs fixing (deploy key or push-from-fw0) |
| `~/.local/share/flatpak/db` on fw3 (empty husk; `/var/lib/flatpak` does not exist, flatpak never installed) | delete — `rm -r ~/.local/share/flatpak` |
| Login password currently imperative (`passwd`) | keep until the gate above is done, then declarative |
| DMS/Hyprland GUI-owned files (`~/.config/hypr/dms/outputs.lua`, DMS theme) | keep — deliberately imperative, documented in hyprland.mod.nix |

## On-host census checklist (read-only; run on fw3, paste results back if you want them triaged)

```bash
# 2. uid/gid allocations vs declared users/groups (report only)
cat /var/lib/nixos/uid-map /var/lib/nixos/gid-map

# 3. root filesystem census: regular files outside expected trees
sudo find / -xdev \( -path /nix -o -path /boot -o -path /home -o -path /proc \
  -o -path /sys -o -path /run -o -path /tmp -o -path /var/lib/nixos \
  -o -path /var/log -o -path /var/lib/tailscale -o -path /etc/ssh \
  -o -path /var/lib/systemd -o -path /var/lib/private \) -prune -o -type f -print | sort

# 4. GC roots census (stale result symlinks, orphaned direnv roots)
nix-store --gc --print-roots | grep -v ^/proc

# expected keepers: /etc/machine-id, /etc/ssh/ssh_host_*, /var/lib/nixos/*,
# /var/lib/tailscale, journal under /var/log, /var/lib/systemd (timers/rtc),
# /var/lib/bluetooth, /var/lib/NetworkManager, /var/lib/fwupd, syncthing state,
# CUPS state under /var/cache+/etc/cups if any.
```

## Boot / Plymouth (issue 4) — findings

The chat diagnosis does not match the config. Current fw3 eval:

- `boot.plymouth.enable = false` (never enabled in any revision of this repo)
- `boot.initrd.systemd.enable = true` (shared `boot.mod.nix` — no mixed initrd)
- `boot.initrd.kernelModules = [ "amdgpu" "btrfs" "dm_mod" ]` — early KMS
  already forced (via nixos-hardware framework-13-7040-amd)
- `boot.kernelParams` = amd_pstate/amdgpu tuning + `loglevel=4`, **no `quiet`**
- `boot.initrd.verbose = true`
- There is no second install's host config in the repo to diff against (hosts:
  fw0, fw3 only; `hardware-configuration.nix` was dropped for disko + inline
  hardware facts in f13b637).

So the "hybrid prompt" is either (a) the running generation predating this
config, or (b) not Plymouth at all: the text prompt printed on the pre-modeset
console surviving the amdgpu takeover as stale framebuffer content.

**Decision: no config change** (a fresh install of this same flake boots
clean, so the shared config is right). Since the boot chain is fully
store-derived, the delta must be host state or a stale generation. Path to
"like a fresh install":

1. Converge the generation: commit/settle the lock (see build gate above), get
   fw3 onto current main, `nixos-rebuild boot --flake .#fw3`, reboot, compare.
   The ESP was already rebuilt from scratch, so bootloader state is fresh.
2. If jank persists, the two remaining host-state suspects vs the fresh
   drive — compare and report, don't change:
   - LUKS header PBKDF params (this volume was formatted longer ago; the
     fresh drive got current cryptsetup defaults):
     `sudo cryptsetup luksDump /dev/disk/by-partlabel/disk-main-luks`
   - systemd-boot console mode: diff `/boot/loader/loader.conf` between the
     two installs.
