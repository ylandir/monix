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

      # PINNED MINECRAFT VERSION. 26.1.2 — the latest STABLE Minecraft release
      # for which the full required performance mod set (Lithium, FerriteCore,
      # Krypton, Spark) all have compatible Fabric builds on Modrinth. The very
      # newest stable, 26.2, is deliberately NOT used: Krypton has no 26.2 build
      # yet (its latest, 0.3.0, tops out at 26.1.2), and pinning ahead of the
      # mods would mean shipping a server the mandated mods can't load. Pin the
      # exact package (fabric-26_1_2), never a floating alias.
      serverPackage = pkgs.fabricServers.fabric-26_1_2;

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
      # metadata for game_version 26.1.2 + loader "fabric"; all are marked
      # server_side, and none require a client-side counterpart.
      mods = {
        # --- Performance (the reason this list exists) ---
        # Lithium — general game-logic optimization. No dependencies.
        Lithium = mod {
          url = "https://cdn.modrinth.com/data/gvQqBUqZ/versions/fQBdPR1m/lithium-fabric-0.24.6%2Bmc26.1.2.jar";
          sha512 = "fac351f5b6150889b9355a01889c35b5798147d4bedb291594a590a2d41909eb8dc494ef0051317bf55886f2fc7fe134abbe2e755098df38473edb2bf43357e9";
        };
        # FerriteCore — cuts server RAM use (shared block-state/model data).
        FerriteCore = mod {
          url = "https://cdn.modrinth.com/data/uXXizFIs/versions/d5ddUdiB/ferritecore-9.0.0-fabric.jar";
          sha512 = "d81fa97e11784c19d42f89c2f433831d007603dd7193cee45fa177e4a6a9c52b384b198586e04a0f7f63cd996fed713322578bde9a8db57e1188854ae5cbe584";
        };
        # Krypton — network stack optimization. This is the mod that pins us to
        # 26.1.2 (no 26.2 build exists yet). No dependencies.
        Krypton = mod {
          url = "https://cdn.modrinth.com/data/fQEb0iXm/versions/kYAGItyj/krypton-0.3.0.jar";
          sha512 = "14233210283a76f3cf435a3b8ddbcbd65a858d2b1a10b88ff643c0a01486dfd2bf1843bd3456cd4fb86cbb3b06f2dea0c4e663b1976a48e96de16d3b5a707ec9";
        };

        # --- Observability ---
        # Spark — profiler / tick + memory monitor. In-game `/spark` commands.
        Spark = mod {
          url = "https://cdn.modrinth.com/data/l6YH9Als/versions/iYFOl6lQ/spark-1.10.173-fabric.jar";
          sha512 = "1dcbf2b76ceacf07523afaeaf63d3625b0318077cc6ce588bb701aea4a494bc2a5179fd2ca5aeda9513c6a2248c2ec590387e8aec6ac9fd8e3d01760bbc3dbfb";
        };

        # --- Quality of life (low-touch, server-side, non-gameplay-altering) ---
        # Ultimate Sleep — one-player / vote-to-sleep so a single player can skip
        # the night without waiting on everyone. Requires Fabric API (below).
        UltimateSleep = mod {
          url = "https://cdn.modrinth.com/data/M1lrtuN1/versions/GkXPriTg/ultimate-sleep-1.2.0%2B26.1-fabric.jar";
          sha512 = "9eaa91b8f8185dd771e15ec47436a4aa8d557acd20c6cc3cc208c09d0e5550d58386365ec46e09a7a217dacab38f8cf8a539846ad34a8aa05707d47c5d964927";
        };
        # ServerCore — server-only performance/QoL tuning (async chunk work,
        # dynamic view distance under load). No dependencies. No client needed.
        ServerCore = mod {
          url = "https://cdn.modrinth.com/data/4WWQxlQP/versions/H6TboTA2/servercore-fabric-1.5.19%2B26.1.2.jar";
          sha512 = "056d56d74508bf34f25ded9323a721be915b9273796100ee81c4a867717364539285b4ae9749e360d6699d485e3fba0561502a8c94979684b0cf79ce8e80afcd";
        };
        # Chunksmith — admin convenience: pre-generate chunks so exploration
        # doesn't stutter. Server-side only, no dependencies.
        Chunksmith = mod {
          url = "https://cdn.modrinth.com/data/4BeAEBIb/versions/cjj0T7Bm/Chunksmith-Fabric-2.2.1%2Bmc26.1.jar";
          sha512 = "e4d7be86bfdc3a4f23acf0a1203b1745aa32c260abef7b81061494b795050861bc9174cbd92a7270edf2f24832e04a20ef9403bbb947c54d885f741f7c9c8f60";
        };

        # --- Required dependency ---
        # Fabric API — required by UltimateSleep (P7dR8mSH). Server-side. Kept
        # last to make clear it is a dependency, not a chosen feature.
        FabricAPI = mod {
          url = "https://cdn.modrinth.com/data/P7dR8mSH/versions/lOQ4tyDD/fabric-api-0.154.2%2B26.1.2.jar";
          sha512 = "8e1b48a2bd10ddd6f1ea59a603a1f28255c2c2f9a2dda93fc196505dee0823eaded2da69d4f154ef654f9faa98e2340ed2b65557ec98637ffe888edc1072912e";
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
              online-mode = true;
              white-list = false;
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
          ProcSubset = "pid";
          RemoveIPC = true;
          # The upstream module already sets UMask=0007; override to the tighter
          # 0077 (no group access) with mkForce to win the merge.
          UMask = lib.mkForce "0077";

          # Syscall allowlist: the standard service set, nothing exotic. The JVM
          # JIT needs W+X pages, so MemoryDenyWriteExecute is deliberately NOT
          # set — it would stop the server from starting.
          SystemCallFilter = [ "@system-service" ];

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
            "10.0.0.0/8" # RFC1918 — incl. the agent-fleet bridge 10.100.0.0/24
            "172.16.0.0/12" # RFC1918
            "192.168.0.0/16" # RFC1918 — home LAN
            "169.254.0.0/16" # link-local
            "fc00::/7" # IPv6 ULA
            "fe80::/10" # IPv6 link-local
          ];
        };
      };
    };
}
