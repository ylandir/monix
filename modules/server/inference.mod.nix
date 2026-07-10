# Local-inference aspect — llama.cpp served through llama-swap, the local
# leg of the model fleet (subscription pools: claude, codex; metered pool:
# openrouter/opencode; this: electricity). Inert until a host sets
# `inference.enable` (same pattern as minecraft.mod.nix / microvm-host.mod.nix).
#
# SHAPE. One llama-swap proxy (upstream nixpkgs module) owns the OpenAI-
# compatible endpoint on `inference.port`. It spawns/kills a llama-server
# per model ON DEMAND from `inference.models` and unloads after `ttl`
# seconds idle — so an idle box holds ~0 model RAM, which matters on a host
# that also fences 48G for the agent fleet. One model active at a time
# (llama-swap's default swap behavior); the fleet-wide ceiling is the
# inference.slice fence set by the host (96G on fw0).
#
# HARDWARE. Tuned for fw0's Strix Halo (Ryzen AI Max+ 395, 128G unified
# LPDDR5X): llama.cpp is built with Vulkan (RADV is the mature path on
# gfx1151 — ROCm support there is younger and more fragile), and models
# fully offload to the iGPU (-ngl 999 in the generated cmd). The iGPU maps
# model weights out of ordinary system RAM via GTT; the kernel's default
# GTT budget is ~half of RAM, which caps models at ~60G on a 128G box, so
# the ttm/amdgpu params below raise it to match the slice fence. Kernel
# params apply on the NEXT REBOOT, not on switch — small models work
# before that; ~60G+ models need the reboot.
#
# THREAT MODEL. Same philosophy as minecraft.mod.nix: the server parses
# untrusted bytes (prompts arrive from the tailnet — and later, if wired,
# from fleet guests), so assume compromise and make it lead nowhere. The
# upstream module already runs it DynamicUser in a near-empty sandbox
# (ProtectSystem=strict, empty caps, @system-service filter); we add the
# GPU device grant it lacks, the inference.slice fence, and an egress
# fence: loopback (llama-swap proxies to its children over 127.0.0.1) and
# the tailnet (its clients) are the ONLY reachable networks — no public
# internet, no LAN, no fleet bridge. NB this also blocks llama-server's
# own -hf model downloading; models are fetched by the operator into
# `inference.modelsDir`, never by the service.
{
  flake.nixosModules.inference =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      inherit (lib.attrsets) mapAttrs;
      inherit (lib.lists) optionals singleton;
      inherit (lib.meta) getExe';
      inherit (lib.modules) mkIf;
      inherit (lib.options) mkEnableOption mkOption;
      inherit (lib.strings) concatStringsSep;
      inherit (lib) types;

      cfg = config.inference;

      llamaCpp = pkgs.llama-cpp.override { vulkanSupport = true; };
      llamaServer = getExe' llamaCpp "llama-server";
    in
    {
      options.inference = {
        enable = mkEnableOption "the tailnet-only llama.cpp/llama-swap local inference server";

        port = mkOption {
          type = types.port;
          default = 8091;
          description = ''
            llama-swap's OpenAI-compatible endpoint. Not 8080: Open WebUI's
            default, kept clash-free for when the gateway stack is enabled.
          '';
        };

        modelsDir = mkOption {
          type = types.str;
          default = "/var/lib/models";
          description = ''
            Where GGUF files live (on fw0 the @models btrfs subvolume). The
            operator downloads into it (owned by the primary user); the
            service only ever reads it.
          '';
        };

        models = mkOption {
          default = { };
          description = ''
            The served catalog: attr name = the model id clients request
            (e.g. `local/gpt-oss-120b` from opencode would name this
            "gpt-oss-120b"). Each entry becomes a llama-swap model with a
            generated llama-server cmd. Adding a model = drop the GGUF in
            modelsDir, add an entry, switch.
          '';
          type = types.attrsOf (
            types.submodule {
              options = {
                file = mkOption {
                  type = types.str;
                  description = "GGUF filename relative to modelsDir (or an absolute path)";
                };
                flags = mkOption {
                  type = types.listOf types.str;
                  default = [ ];
                  example = [
                    "-c"
                    "32768"
                  ];
                  description = "extra llama-server flags (context size, jinja templates, ...)";
                };
                ttl = mkOption {
                  type = types.int;
                  default = 600;
                  description = "seconds idle before llama-swap unloads the model";
                };
                aliases = mkOption {
                  type = types.listOf types.str;
                  default = [ ];
                  description = "extra model ids that resolve to this entry";
                };
              };
            }
          );
        };
      };

      config = mkIf cfg.enable {
        services.llama-swap = {
          enable = true;
          # Bind everywhere; reachability is the firewall's job (the fw0
          # pattern): zero public inbound ports, tailscale0 trusted, and the
          # fleet bridge admits only squid's 3128 — so this is tailnet-only
          # until a bridge pinhole is deliberately opened for the guests.
          listenAddress = "0.0.0.0";
          inherit (cfg) port;
          openFirewall = false;

          settings = {
            # A cold 60G model is minutes of NVMe -> GTT load; don't let the
            # health check give up mid-load (default 120s).
            healthCheckTimeout = 600;

            models = mapAttrs (name: m: {
              # ''${PORT} is llama-swap's macro (a fresh port per spawn),
              # escaped so Nix passes it through verbatim.
              cmd = concatStringsSep " " (
                [
                  llamaServer
                  "--port \${PORT}"
                  "--host 127.0.0.1" # children speak only to the proxy
                  "-m ${if lib.strings.hasPrefix "/" m.file then m.file else "${cfg.modelsDir}/${m.file}"}"
                  "-ngl 999" # full iGPU offload — unified memory, no VRAM cliff
                  "--no-webui" # llama-swap's own UI serves the humans
                ]
                ++ m.flags
              );
              inherit (m) ttl aliases;
            }) cfg.models;
          };
        };

        systemd.services.llama-swap.serviceConfig = {
          # Count model RAM against the host's inference fence, not the
          # default system slice.
          Slice = "inference.slice";

          # The upstream sandbox leaves PrivateDevices=false but grants no
          # device class; DynamicUser has no groups. Open exactly the DRM
          # render path Vulkan needs and nothing else.
          SupplementaryGroups = [
            "render"
            "video"
          ];
          DevicePolicy = "closed";
          DeviceAllow = [ "char-drm rw" ];

          # Anti-pivot egress fence (cf. minecraft.mod.nix, but tighter: no
          # public internet at all). Allow loopback — llama-swap reaches its
          # spawned llama-servers over 127.0.0.1 — the tailnet its human
          # clients live on, and (only when this host also runs the agent
          # fleet) the guest bridge subnet, so drones can call local models
          # through the matching br-agents pinhole (microvm-host.mod.nix).
          # Deny everything else, inbound and out.
          IPAddressAllow = [
            "127.0.0.0/8"
            "::1"
            "100.64.0.0/10" # tailnet (CGNAT range)
          ]
          ++ optionals config.agentFleet.enable [
            "10.100.0.0/24" # the br-agents guest subnet (see microvm-host.mod.nix)
          ];
          IPAddressDeny = "any";
        };

        # GPU memory budget for big models (see header; applies on reboot).
        # GTT is a LIMIT, not a reservation — an idle box pays nothing.
        # 96G to match fw0's inference.slice fence: 98304 MiB / 25165824
        # 4K-pages. page_pool_size caps TTM's cached-page reuse pool at the
        # same bound.
        boot.kernelParams = [
          "amdgpu.gttsize=98304"
          "ttm.pages_limit=25165824"
          "ttm.page_pool_size=25165824"
        ];

        # The models directory: operator-owned (downloads happen as the
        # primary user with plain curl/hf), world-readable for the
        # DynamicUser service.
        systemd.tmpfiles.rules = singleton "d ${cfg.modelsDir} 0755 ${config.primaryUser} users -";

        # llama-cli / llama-bench / llama-gguf etc. on the host for pulling,
        # inspecting, and benchmarking models outside the service sandbox.
        environment.systemPackages = singleton llamaCpp;
      };
    };
}
