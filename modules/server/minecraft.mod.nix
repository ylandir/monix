# Minecraft server aspect — one declarative Fabric server, server-side mods
# only, reachable over the tailnet and nowhere else. Inert until a host sets
# `minecraft.enable`; imported on every host, so gated explicitly to stay OFF
# on desktops and non-fleet servers (same pattern as microvm-host.mod.nix).
#
# PHILOSOPHY / THREAT MODEL. A Minecraft server is a JVM that parses untrusted
# bytes from every connecting player and runs a mod loader — a real remote
# attack surface. We treat a full server compromise as plausible and make it
# lead nowhere:
#   - Reachability: openFirewall = false. fw0 opens ZERO public inbound ports;
#     tailscale0 is the sole trusted interface, so players reach the server by
#     being on the tailnet, not by a port-forward. No LAN/WAN exposure.
#   - Blast radius: the unit runs unprivileged under the `minecraft` user with
#     the nix-minecraft module's already-strong sandbox, and we tighten it
#     further below (ProtectSystem=strict, empty caps, syscall allowlist) so a
#     broken-out JVM lands in an almost-empty room with only its own world dir
#     writable.
#   - Anti-pivot egress fence: the killer control. online-mode needs the public
#     Mojang session servers and players live on the tailnet, so the service may
#     reach those two — but it must NOT be a springboard onto localhost, the
#     home LAN, or the agent-fleet microVM bridge. A systemd IP allow/deny fence
#     enforces exactly that (see IPAddress* below).
#
# Mods are server-side ONLY: players join with 100% stock vanilla clients, so
# anything needing a client-side counterpart is forbidden. Every jar is pinned
# by URL + sha512 from Modrinth (nix-minecraft's documented `fetchurl` pattern),
# and every version is verified against the pinned Minecraft version from
# Modrinth's own metadata — never guessed.
{ inputs, ... }:
{
  flake.nixosModules.minecraft =
    {
      config,
      pkgs,
      lib,
      ...
    }:
    let
      inherit (lib.lists) singleton;
      inherit (lib.modules) mkIf;
      inherit (lib.options) mkEnableOption;

      cfg = config.minecraft;
      networkFences = import ../../lib/network-fences.nix;

      # PINNED MINECRAFT VERSION. 26.2 — the latest stable release, unblocked
      # 2026-07-19 when Krypton 0.3.1 shipped its 26.2 build (the last of the
      # required performance mod set to update). Bump rule: server pin, every
      # mod hash below, and the players' clients move together. Pin the exact
      # package (fabric-26_2), never a floating alias.
      # jre override: Minecraft 26.x class files are Java 25 (class version
      # 69), but nix-minecraft's package wraps this server with a Java 21
      # runtime — the JVM dies at launch with UnsupportedClassVersionError
      # (found live on fw0; invisible in the journal because tmux swallows
      # the crash). Pin the runtime the game actually needs.
      serverPackage = pkgs.fabricServers.fabric-26_2.override {
        jre_headless = pkgs.jdk25_headless;
      };

      dataDir = config.services.minecraft-servers.dataDir; # /srv/minecraft
      worldDir = "${dataDir}/main"; # per-server subdir == the server name below

      # A Modrinth mod jar, pinned by CDN URL + sha512 (the hash Modrinth's API
      # reports). Kept as a helper so every entry reads the same and the pinning
      # discipline is obvious.
      mod =
        {
          url,
          sha512,
        }:
        pkgs.fetchurl { inherit url sha512; };

      # THE MOD SET. Every version below was checked against Modrinth version
      # metadata for game_version 26.2 + loader "fabric"; all are marked
      # server_side, and none require a client-side counterpart.
      mods = {
        # --- Performance (the reason this list exists) ---
        # Lithium — general game-logic optimization. No dependencies.
        Lithium = mod {
          url = "https://cdn.modrinth.com/data/gvQqBUqZ/versions/UPNexAfy/lithium-fabric-0.25.2%2Bmc26.2.jar";
          sha512 = "db676376c05b7e912cdae5aad9e51f125adc1554ae2b204599ccb598751921aedbac98e97b9cba0333b6b52488c6b75c915a7dbd50436f97800387fe1aad1c50";
        };
        # FerriteCore — cuts server RAM use (shared block-state/model data).
        FerriteCore = mod {
          url = "https://cdn.modrinth.com/data/uXXizFIs/versions/d5ddUdiB/ferritecore-9.0.0-fabric.jar";
          sha512 = "d81fa97e11784c19d42f89c2f433831d007603dd7193cee45fa177e4a6a9c52b384b198586e04a0f7f63cd996fed713322578bde9a8db57e1188854ae5cbe584";
        };
        # Krypton — network stack optimization. Historically the version gate
        # (0.3.1 was the last of the set to reach 26.2). No dependencies.
        Krypton = mod {
          url = "https://cdn.modrinth.com/data/fQEb0iXm/versions/5WeL0Nkz/krypton-0.3.1.jar";
          sha512 = "b8d9af34cd0050493afb8a6232cb8f785daa9d8887b7045f6e6a53c6bb9b5ffc4318fd9b0347a940eacfeba4773f10cb80ae0be1e79ce4c1888f96eda21e564e";
        };

        # --- Observability ---
        # Spark — profiler / tick + memory monitor. In-game `/spark` commands.
        Spark = mod {
          url = "https://cdn.modrinth.com/data/l6YH9Als/versions/iYFOl6lQ/spark-1.10.173-fabric.jar";
          sha512 = "1dcbf2b76ceacf07523afaeaf63d3625b0318077cc6ce588bb701aea4a494bc2a5179fd2ca5aeda9513c6a2248c2ec590387e8aec6ac9fd8e3d01760bbc3dbfb";
        };

        # --- Quality of life (low-touch, server-side, non-gameplay-altering) ---
        # (Ultimate Sleep — one-player-skips-the-night — was here and got
        # removed by request: the user wants vanilla all-players-must-sleep,
        # which is exactly what NO sleep mod does.)
        #
        # ServerCore — server-only performance/QoL tuning (async chunk work,
        # dynamic view distance under load). No dependencies. No client needed.
        ServerCore = mod {
          url = "https://cdn.modrinth.com/data/4WWQxlQP/versions/edrtnY9v/servercore-fabric-1.5.19%2B26.2.jar";
          sha512 = "aa4cfc93f8e02172910302444330e37713dfcf2047d28e55eb7323a3cd5d51493374a0959aa3e626ec2bf43fc707a755508b83454bb34b6d57d65c069929074b";
        };
        # Chunksmith — admin convenience: pre-generate chunks so exploration
        # doesn't stutter. Server-side only, no dependencies.
        Chunksmith = mod {
          url = "https://cdn.modrinth.com/data/4BeAEBIb/versions/StOy04qm/chunksmith-3.1.1%2B26.2.jar";
          sha512 = "b8bbcd54e064e6a1b33a5ae290077ccff79b5430624271772d82a368670b2474ce2f2c3cd95318778ee7b4c3e5fd5cbc511d43459bb7862c67668e4737cff8d7";
        };

        # --- Library ---
        # Fabric API (P7dR8mSH) — no current mod requires it (its dependent,
        # Ultimate Sleep, was removed) but it's kept deliberately: most Fabric
        # mods need it, so it being present means future mod additions just
        # work. Server-side, inert on its own.
        FabricAPI = mod {
          url = "https://cdn.modrinth.com/data/P7dR8mSH/versions/lVXlbH4w/fabric-api-0.155.2%2B26.2.jar";
          sha512 = "cc56984378a27c5bcd56374d6ffbb27a45c6bf3355add2ac6be9817ccac5854362249bf9d0147eb271a70fda2716129204e240d53c9aa876a2a7861f4c7f880f";
        };
      };
    in
    {
      # Bring in the upstream service module (defines services.minecraft-servers).
      # It stays inert until we enable it below, so importing it unconditionally
      # on every host is safe.
      imports = singleton inputs.nix-minecraft.nixosModules.minecraft-servers;

      options.minecraft.enable = mkEnableOption "the declarative tailnet-only Fabric Minecraft server";

      config = mkIf cfg.enable {
        # The overlay brings `pkgs.fabricServers`, the per-version server
        # packages, and the launcher wrapper into scope. From nix-minecraft's
        # own (pinned) nixpkgs — see the input comment in flake.nix.
        nixpkgs.overlays = singleton inputs.nix-minecraft.overlay;

        services.minecraft-servers = {
          enable = true;

          # systemd-socket management instead of the default tmux: the server
          # runs in the FOREGROUND, so its console output (and any crash)
          # lands in the journal instead of being swallowed by a detached
          # tmux session — a Java-21-vs-25 launch failure was invisible for
          # exactly that reason. Console commands go via the socket:
          # `echo save-all > /run/minecraft-server/main.stdin`.
          managementSystem.tmux.enable = false;
          managementSystem.systemd-socket.enable = true;

          # EULA. Accepting Mojang's EULA is a precondition of running a server;
          # stated explicitly here rather than hidden.
          eula = true;

          # No public port. Reachability is tailnet-only by construction (see
          # the module header) — this is the load-bearing firewall statement.
          openFirewall = false;

          servers.main = {
            enable = true;
            autoStart = true;

            package = serverPackage;

            # JVM HEAP — a small server: start at 2G, cap at 4G. Well within the
            # services.slice 16G fence, leaving headroom for everything else.
            jvmOpts = "-Xms2G -Xmx4G";

            # Mods are symlinked read-only into the server's `mods/` dir. Using
            # linkFarmFromDrvs over the pinned jars is nix-minecraft's documented
            # pattern; the set is fully reproducible from the hashes above.
            symlinks.mods = pkgs.linkFarmFromDrvs "mods" (lib.attrsets.attrValues mods);

            # SERVER PROPERTIES — small-server defaults. online-mode true means
            # Mojang-authenticated accounts only (and is why the egress fence has
            # to permit the public Mojang session servers). No whitelist.
            serverProperties = {
              server-port = 25565;
              max-players = 5;
              difficulty = "normal";
              # Captain-chosen seed for the 26.2 world remake (2026-07-19).
              # Only consulted at world creation; inert for an existing world.
              level-seed = "1133044835122437667";
              online-mode = true;
              white-list = false;
              # Generous sightlines: fw0 has huge headroom for 3-5 players, and
              # the extra chunks are render-only. simulation-distance stays at
              # the vanilla default (10) so mob/crop/redstone ticking — the
              # gameplay-visible part — is untouched. ServerCore dynamically
              # walks view-distance back down if the tick rate ever suffers.
              # (Cost grows with the square of the distance — 20 is ~55% more
              # loaded chunks than 16; fine here, think before going higher.)
              view-distance = 20;
              motd = "fw0 // tailnet survival — stock clients welcome";
              # Bind to all interfaces: the firewall (not a bind address) is what
              # keeps this tailnet-only, and tailscale0 is a normal interface.
              server-ip = "";
            };
          };
        };

        # HARDENING — the nix-minecraft module already ships a strong sandbox
        # (unprivileged `minecraft` user, empty CapabilityBoundingSet, empty
        # DeviceAllow, PrivateDevices/PrivateTmp/PrivateUsers, Protect{Clock,
        # ControlGroups,Home,Hostname,Kernel*}, ProtectProc=invisible,
        # Restrict{AddressFamilies=[AF_UNIX AF_INET AF_INET6],Namespaces,
        # Realtime,SUIDSGID}, SystemCallArchitectures=native). We do NOT fight
        # any of that — we add only the directives it leaves out, and the egress
        # fence. Per-server serviceConfig merges LAST in the module, so these win.
        systemd.services.minecraft-server-main.serviceConfig = {
          # Put the world in the services fence alongside the other non-agent,
          # non-inference workloads.
          Slice = "services.slice";

          # --- Filesystem: read-only world, one writable path ---
          # ProtectSystem=strict makes the ENTIRE filesystem read-only except
          # the paths we name — so the world dir is the only place a compromised
          # server can write. (RuntimeDirectory=/run/minecraft, set by the
          # module, stays writable automatically.)
          ProtectSystem = "strict";
          ReadWritePaths = [ worldDir ];
          NoNewPrivileges = true;
          # NO ProcSubset=pid: it hides /proc/mounts (and cpuinfo/meminfo),
          # which Java's NIO needs for file-store lookups — Minecraft's
          # world/datapack loading dies with "Mount point not found" →
          # "Overworld settings missing" (found live on fw0). Upstream's
          # ProtectProc=invisible still hides other processes' entries.
          RemoveIPC = true;
          # The upstream module already sets UMask=0007; override to the tighter
          # 0077 (no group access) with mkForce to win the merge.
          UMask = lib.mkForce "0077";

          # Syscall allowlist: the standard service set, nothing exotic. The JVM
          # JIT needs W+X pages, so MemoryDenyWriteExecute is deliberately NOT
          # set — it would stop the server from starting.
          #
          # EPERM instead of the default kill-on-violation: Spark's native
          # async-profiler probes perf_event_open (outside @system-service);
          # under the default action seccomp KILLS the JVM mid-startup —
          # found live on fw0, where the kill landed during first-boot world
          # creation and left a half-written world that broke every restart
          # ("Overworld settings missing"). With EPERM the probe fails
          # gracefully and Spark falls back to its Java sampler; the filter
          # blocks exactly what it blocked before.
          SystemCallFilter = [ "@system-service" ];
          SystemCallErrorNumber = "EPERM";

          # --- The anti-pivot egress fence (the key control) ---
          # systemd checks IPAddressAllow BEFORE IPAddressDeny; anything matched
          # by neither is ALLOWED. So: explicitly allow the tailnet, explicitly
          # deny every private/loopback/link-local range (which includes the
          # agent-fleet microVM bridge 10.100.0.0/24 — inside 10.0.0.0/8), and
          # let the public internet (Mojang session/auth servers, needed for
          # online-mode) fall through as allowed. Result: reachable to tailnet
          # players and Mojang, but unable to touch localhost, the home LAN, or
          # the fleet bridge.
          IPAddressAllow = [
            "100.64.0.0/10" # tailnet (CGNAT range)
            # systemd-resolved's stub resolver. The JVM resolves Mojang's
            # session servers through /etc/resolv.conf → 127.0.0.53, which the
            # loopback deny below would otherwise block — silently breaking
            # online-mode auth. A /32 pinhole to the stub (nothing else binds
            # this address) keeps DNS working while the rest of loopback, and
            # every service on 127.0.0.1, stays unreachable.
            "127.0.0.53/32"
          ];
          IPAddressDeny = [
            "127.0.0.0/8" # loopback / other localhost services
            "::1"
          ] ++ networkFences.privateRanges;
        };
      };
    };
}
