# Cockpit: the user's primary interactive agent session lives on the host that
# enables this. Claude Code over tmux/SSH and opencode web are interchangeable
# frontends to the same captain's seat. It carries full user privileges
# (contrast with the locked-down fleet workers of agent-vm.mod.nix).
#
# The agent tooling itself (claude-code, codex, CLAUDE.md) comes from the
# existing home aspects in packages.mod.nix / claude.mod.nix, which gate on
# `isDesktop || cockpit.enable`.
{ inputs, ... }:
{
  flake.homeModules.cockpit =
    {
      config,
      lib,
      osConfig,
      ...
    }:
    let
      guide = import ../../lib/fleet-guide.nix;
      inherit (lib.attrsets) genAttrs;
      inherit (lib.lists) concatMap map;
      inherit (lib.modules) mkIf;
      userHome = "/home/${osConfig.primaryUser}";
      monixDir = "${userHome}/ark/monix";
      holdDir = "${userHome}/hold";
      cockpitDir = "${userHome}/cockpit";
      cockpitMemoryDir = "${userHome}/cockpit/memory";
      claudeMemoryDir = "${userHome}/.claude/projects/-home-max-cockpit/memory";
      # Claude's cockpit policy is canonical. Render the shared explicit
      # permissions in both frontend-specific formats.
      gitReadCommands = [
        "status*"
        "diff*"
        "log*"
        "show*"
        "blame*"
        "rev-parse*"
        "merge-base*"
        "ls-files*"
        "ls-tree*"
        "cat-file*"
        "branch --show-current*"
        "remote -v"
        "tag --list*"
      ];
      gitReadPermissions = concatMap (command: [
        "git ${command}"
        "git -C * ${command}"
      ]) gitReadCommands;
      claudeBashPermissions = [
        "sudo -n -u fleet-operator fleet *"
        "fleet dispatch *"
        "ship-status"
        "nix build *"
        "nix eval *"
        "nix flake *"
        "nix run nixpkgs#shellcheck *"
        "nix search *"
        "tailscale status*"
      ]
      ++ gitReadPermissions
      ++ [
        # The captain's standing policy is "commit and test freely, push only
        # on his word": stage/commit never prompt, push remains absent.
        "git -C ${monixDir} add *"
        "git -C ${monixDir} commit *"
        # journalctl mutations require root; systemctl gets only read verbs.
        "journalctl*"
        "systemctl status*"
        "systemctl show*"
        "systemctl cat*"
        "systemctl list-units*"
        "systemctl list-timers*"
        "systemctl list-unit-files*"
        "systemctl list-dependencies*"
        "systemctl is-active*"
        "systemctl is-enabled*"
        "systemctl is-failed*"
        "systemctl --failed*"
        "systemctl --user status*"
        "systemctl --user show*"
        "systemctl --user cat*"
        "systemctl --user is-active*"
        "systemctl --user list-units*"
        "systemctl --user list-timers*"
      ]
      ++ [
        # Read-only inspection commands. Claude's built-in classifier already
        # auto-approves most of these; listing them explicitly is what stops
        # OpenCode (static globs only) prompting on every grep/ls. Anything
        # that mutates state, writes files by design, or reaches the network
        # (curl, ssh, sed -i, rm, pkill, nix shell/run) stays prompt-bound.
        "echo *"
        "grep *"
        "rg *"
        "ls"
        "ls *"
        "head *"
        "tail *"
        "wc *"
        "stat *"
        "du *"
        "df"
        "df *"
        "file *"
        "readlink *"
        "realpath *"
        "command -v *"
        "pgrep *"
        "tree *"
        "sleep *"
        "mkdir -p *"
      ];
      claudeFilePermissions = [
        monixDir
        cockpitMemoryDir
        claudeMemoryDir
      ];
      claudeAllow =
        map (command: "Bash(${command})") claudeBashPermissions
        ++ concatMap (path: [
          "Read(/${path}/**)"
          "Edit(/${path}/**)"
          "Write(/${path}/**)"
        ]) claudeFilePermissions
        ++ [
          "WebFetch(domain:github.com)"
          "WebSearch"
          "SendUserFile"
        ];
      # OpenCode evaluates the final matching permission rule. Keep the
      # catch-all first, then append the current Claude-approved capabilities.
      mkOpenCodeRules = patterns: { "*" = "ask"; } // genAttrs patterns (_: "allow");
      # OpenCode strips the leading slash before checking file-tool paths, but
      # external_directory checks the same path in absolute form.
      opencodeFilePermissions = concatMap (path: [
        "${path}/**"
        "${lib.strings.removePrefix "/" path}/**"
      ]) claudeFilePermissions;
      # Claude permits reads within its working directory. OpenCode's explicit
      # read catch-all would otherwise prompt for ordinary cockpit files such
      # as AGENTS.md, while edits must remain limited to the canonical paths.
      opencodeReadPermissions = opencodeFilePermissions ++ [
        "${cockpitDir}/**"
        "${lib.strings.removePrefix "/" cockpitDir}/**"
        "${holdDir}/**"
        "${lib.strings.removePrefix "/" holdDir}/**"
      ];
      opencodePermissions = {
        # Claude also has a validated read-only command classifier. OpenCode
        # only has static globs, so unmatched commands must stay prompt-bound
        # rather than broadening this list unsafely.
        bash = mkOpenCodeRules claudeBashPermissions;
        read = mkOpenCodeRules opencodeReadPermissions;
        edit = mkOpenCodeRules opencodeFilePermissions;
        external_directory = mkOpenCodeRules (map (path: "${path}/**") claudeFilePermissions);
        # Claude permits its built-in discovery and delegation tools without
        # explicit allowlist entries; preserve that behavior in OpenCode.
        glob = "allow";
        grep = "allow";
        list = "allow";
        task = "allow";
        # OpenCode cannot scope webfetch by domain, so keep it stricter than
        # Claude's github.com-only allow rather than permitting every domain.
        webfetch = "ask";
        websearch = "allow";
        todowrite = "allow";
        question = "allow";
        skill = "allow";
      };
      # Top-level permissions are appended after built-in agent rules. Restore
      # the restrictions that make Plan non-editing and Explore read-only.
      opencodePlanPermissions = opencodePermissions // {
        edit = "deny";
        task = {
          "*" = "allow";
          general = "deny";
        };
      };
      opencodeExplorePermissions = {
        "*" = "deny";
        inherit (opencodePermissions)
          bash
          external_directory
          glob
          grep
          list
          read
          webfetch
          websearch
          ;
      };
    in
    {
      config = mkIf osConfig.cockpit.enable {
        home.file."cockpit/AGENTS.md" = {
          force = true;
          text = guide.system + guide.pilot;
        };
        home.file."cockpit/CLAUDE.md" = {
          force = true;
          text = "@AGENTS.md\n";
        };

        # OpenCode's native permissions are generated from the established
        # Claude cockpit allowlist. Its config is normally mutable state, but
        # this cockpit policy must not drift by frontend.
        home.file.".config/opencode/opencode.jsonc" = {
          force = true;
          text = builtins.toJSON {
            "$schema" = "https://opencode.ai/config.json";
            provider.local = {
              npm = "@ai-sdk/openai-compatible";
              name = "fw0 local inference";
              options = {
                baseURL = "http://127.0.0.1:8091/v1";
                apiKey = "local";
              };
              models = {
                "qwen3.6-35b-a3b" = { };
                "gpt-oss-120b" = { };
              };
            };
            permission = opencodePermissions;
            agent.plan.permission = opencodePlanPermissions;
            agent.explore.permission = opencodeExplorePermissions;
          };
        };

        # OpenCode shortcuts for the vendor-neutral ship procedures in AGENTS.md.
        home.file.".config/opencode/commands/launch.md" = {
          force = true;
          text = ''
            ---
            description: Pre-flight — orient in the cockpit and report ship status
            ---

            Run the pre-flight ("launch the ship") from AGENTS.md:

            1. Read `~/cockpit/memory/HANDOFF.md` (current shift state) and
               `~/cockpit/memory/MEMORY.md`, and open every memory relevant
               to active or open work.
            2. Run `sudo -n -u fleet-operator fleet health` and then `fleet status`
               (each standalone, never chained).
            3. Report in a few lines: ship status, drone-fleet health, the open backlog
               and loose ends, and anything time-sensitive. Then hold for a heading from
               the captain — don't start work unprompted.
          '';
        };
        home.file.".config/opencode/commands/dock.md" = {
          force = true;
          text = ''
            ---
            description: Dock the ship — graceful end-of-shift wrap-up
            ---

            Run the docking procedure ("dock the ship") from AGENTS.md:

            1. Sweep loose ends: `sudo -n -u fleet-operator fleet health`
               (running tasks, pending questions), background jobs, and
               `git status` + unpushed commits in `~/ark/monix` and any other
               repo touched this shift.
            2. Memory hygiene: durable facts → memory files (update MEMORY.md
               index lines); archive/delete resolved memories.
            3. REWRITE `~/cockpit/memory/HANDOFF.md` in full (shift change).
            4. Report the docking checklist and hold for the captain's final
               word: repo state (uncommitted/unpushed — pushing needs his
               explicit say), work still running, commits awaiting a switch,
               anything that shouldn't wait for next shift.
          '';
        };

        # Durable cockpit memory lives at the vendor-neutral path for real:
        # ~/cockpit/memory is the actual directory (mutable state, not managed
        # here). Claude's per-project auto-memory location is a symlink INTO
        # it, so the Claude harness reads/writes the same files every other
        # frontend sees — no vendor owns the storage.
        home.file.".claude/projects/-home-max-cockpit/memory" = {
          force = true;
          source = config.lib.file.mkOutOfStoreSymlink ("/home/${osConfig.primaryUser}/cockpit/memory");
        };

        # Claude Code project permissions, declarative so the allowlist can
        # never drift from what AGENTS.md promises ("fleet commands are
        # pre-authorized"). The whole scoped-sudo fleet hop is allowed as one
        # prefix: the immutable fleet tool itself is the boundary, so listing
        # subcommands here would only re-create drift when the tool grows one.
        # Everything else is read-only or build-sandboxed.
        home.file."cockpit/.claude/settings.json" = {
          force = true;
          text = builtins.toJSON {
            permissions = {
              allow = claudeAllow;
              # Transcript audit found ~400 prompts caused solely by `cd
              # ~/ark/monix && …` leaving the cockpit working directory.
              # Treat the flake repo and the projects dir as additional
              # working directories: cd/read stop prompting there, while
              # edits still follow the explicit Edit/Write rules above.
              additionalDirectories = [
                monixDir
                holdDir
              ];
            };
          };
        };

        # /launch — Claude-specific shortcut for the vendor-neutral spoken
        # "launch the ship" pre-flight in AGENTS.md.
        home.file."cockpit/.claude/commands/launch.md" = {
          force = true;
          text = ''
            ---
            description: Pre-flight — orient in the cockpit and report ship status
            ---

            Run the pre-flight ("launch the ship") from AGENTS.md:

            1. Read `~/cockpit/memory/HANDOFF.md` (current shift state) and
               `~/cockpit/memory/MEMORY.md`, and open every memory relevant
               to active or open work.
            2. Run `sudo -n -u fleet-operator fleet health` and then `fleet status`
               (each standalone, never chained).
            3. Report in a few lines: ship status, drone-fleet health, the open backlog
               and loose ends, and anything time-sensitive. Then hold for a heading from
               the captain — don't start work unprompted.
          '';
        };

        # /dock — Claude-specific shortcut for the vendor-neutral spoken
        # "dock the ship" end-of-shift in AGENTS.md.
        home.file."cockpit/.claude/commands/dock.md" = {
          force = true;
          text = ''
            ---
            description: Dock the ship — graceful end-of-shift wrap-up
            ---

            Run the docking procedure ("dock the ship") from AGENTS.md:

            1. Sweep loose ends: `sudo -n -u fleet-operator fleet health`
               (running tasks, pending questions), background jobs, and
               `git status` + unpushed commits in `~/ark/monix` and any other
               repo touched this shift.
            2. Memory hygiene: durable facts → memory files (update MEMORY.md
               index lines); archive/delete resolved memories.
            3. REWRITE `~/cockpit/memory/HANDOFF.md` in full (shift change).
            4. Report the docking checklist and hold for the captain's final
               word: repo state (uncommitted/unpushed — pushing needs his
               explicit say), work still running, commits awaiting a switch,
               anything that shouldn't wait for next shift.
          '';
        };

        # /handoff — Claude-specific shortcut for the vendor-neutral spoken
        # "shift change" in AGENTS.md.
        home.file."cockpit/.claude/commands/handoff.md" = {
          force = true;
          text = ''
            ---
            description: Shift change — rewrite the memory handoff for the next session
            ---

            Run the shift change from AGENTS.md: REWRITE `~/cockpit/memory/HANDOFF.md`
            in full (replace, never append) — what just happened, what's in flight
            (ids/commits), next concrete actions, warnings for the next shift. Under
            ~40 lines; durable facts graduate to memory files (update their MEMORY.md
            index lines). Then confirm the handoff is written in one line.
          '';
        };
      };
    };

  flake.nixosModules.cockpit =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      inherit (lib.lists) singleton;
      inherit (lib.meta) getExe;
      inherit (lib.modules) mkIf;
      inherit (lib.options) mkEnableOption mkOption;
      inherit (lib) types;
    in
    {
      options.cockpit.enable = mkEnableOption "the persistent cockpit session role on this host";

      options.cockpit.webEnable = mkEnableOption "the opencode web cockpit seat";

      options.cockpit.webEnvFile = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          EnvironmentFile holding OPENCODE_SERVER_PASSWORD=<basic-auth pw>
          for the opencode web UI; null = no web UI. This is the app-local
          password layer. If the UI is exposed beyond the tailnet, put
          Cloudflare Access in front too: opencode web controls a shell-capable
          cockpit seat.
        '';
      };

      options.cockpit.webTunnelTokenFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = ''
          Cloudflare Tunnel connector token for exposing the opencode web
          cockpit at ai.su.is; null = no public tunnel. The public hostname
          and origin service are managed in Cloudflare Zero Trust.
        '';
      };

      config = mkIf config.cockpit.enable {
        assertions = [
          {
            assertion = config.cockpit.webTunnelTokenFile == null || config.cockpit.webEnable;
            message = "cockpit.webTunnelTokenFile requires cockpit.webEnable";
          }
        ];

        # tmux is the session's persistence layer; the binary is already
        # system-wide (packages-shell-utils), this adds the /etc config.
        programs.tmux.enable = true;
        programs.tmux.historyLimit = 50000;

        # The cockpit is where secrets get created/rotated (`agenix -e ...`
        # from the repo root) — fleet credentials in particular originate
        # here (`claude setup-token`, Codex's auth.json). python3/jq keep
        # everyday data munging off the `nix shell nixpkgs#python3` path,
        # which prompted on every use (interpreters are never allowlisted).
        environment.systemPackages = [
          inputs.agenix.packages.${pkgs.stdenv.hostPlatform.system}.default
          pkgs.python3
          pkgs.jq
        ];

        # OPENCODE WEB — the cockpit from a browser: opencode's bundled
        # server + web UI, running AS the primary user (this is the human's
        # seat — it needs their auth.json, home, and full tooling, so it is
        # deliberately NOT filesystem-sandboxed like a tenant service). Binds
        # to loopback behind nginx; Cloudflare Tunnel is the public ingress
        # when enabled. nginx keeps ai.su.is stable on :4096.
        services.nginx = mkIf config.cockpit.webEnable {
          enable = true;
          recommendedProxySettings = true;
          virtualHosts."opencode-web-cockpit" = {
            listen = singleton {
              addr = "127.0.0.1";
              port = 4096;
            };
            locations."/" = {
              proxyPass = "http://127.0.0.1:4097";
              proxyWebsockets = true;
              extraConfig = ''
                proxy_buffering off;
              '';
            };
          };
        };

        systemd.services.opencode-web = mkIf config.cockpit.webEnable {
          description = "opencode web UI cockpit seat";
          wantedBy = [ "multi-user.target" ];
          wants = [ "network-online.target" ];
          after = [ "network-online.target" ];
          # Agents spawned from web sessions need the same tools a login
          # shell would have: system-wide packages plus the user's own
          # profile (where claude-code/codex/opencode themselves live).
          # NixOS privilege wrappers must precede the unwrapped packages in
          # the system profile; otherwise sudo finds its non-setuid binary.
          path = [
            "/run/wrappers"
            "/run/current-system/sw"
            "/etc/profiles/per-user/${config.primaryUser}"
          ];
          serviceConfig = {
            User = config.primaryUser;
            Group = "users";
            Slice = "cockpit.slice";
            EnvironmentFile = mkIf (config.cockpit.webEnvFile != null) config.cockpit.webEnvFile;
            WorkingDirectory = "/home/${config.primaryUser}/cockpit";
            ExecStart = "${getExe pkgs.opencode} web --hostname 127.0.0.1 --port 4097 --cors https://ai.su.is --print-logs";
            Restart = "always";
            RestartSec = 3;
          };
        };

        # The captain's seat legitimately runs builds and tools, but a remote
        # session still must not consume every byte or PID on the host.
        systemd.slices.cockpit.sliceConfig = mkIf config.cockpit.webEnable {
          MemoryHigh = "48G";
          MemoryMax = "64G";
          TasksMax = 8192;
        };

        systemd.services.opencode-web-tunnel = mkIf (config.cockpit.webTunnelTokenFile != null) {
          description = "Cloudflare Tunnel for opencode web";
          wantedBy = [ "multi-user.target" ];
          partOf = [
            "nginx.service"
            "opencode-web.service"
          ];
          wants = [
            "network-online.target"
            "nginx.service"
            "opencode-web.service"
          ];
          after = [
            "network-online.target"
            "nginx.service"
            "opencode-web.service"
          ];
          serviceConfig = {
            DynamicUser = true;
            LoadCredential = [ "token:${config.cockpit.webTunnelTokenFile}" ];
            ExecStart = "${getExe pkgs.cloudflared} tunnel --no-autoupdate run --token-file %d/token";
            Restart = "always";
            RestartSec = 5;
          };
          environment = {
            TUNNEL_TRANSPORT_PROTOCOL = "http2";
          };
        };

        # Cloudflare Access is configured outside Nix. Probe it without a
        # cookie so dashboard drift cannot silently turn this shell-capable
        # endpoint public again; a failed check remains visible in systemd and
        # `fleet health` until corrected.
        systemd.services.opencode-web-access-check = mkIf (config.cockpit.webTunnelTokenFile != null) {
          description = "Verify Cloudflare Access protects the opencode cockpit";
          wants = [ "network-online.target" ];
          after = [
            "network-online.target"
            "opencode-web-tunnel.service"
          ];
          path = [ pkgs.curl ];
          serviceConfig = {
            Type = "oneshot";
            DynamicUser = true;
            NoNewPrivileges = true;
            PrivateTmp = true;
            ProtectHome = true;
            ProtectSystem = "strict";
          };
          script = ''
            # Three attempts per URL: a single timeout or Cloudflare hiccup
            # is not dashboard drift, and since unit failures page the alert
            # room (alerts.mod.nix) a one-shot probe was too trigger-happy.
            # An endpoint that actually answers without demanding Access
            # still fails every attempt and alerts within the same run.
            check() {
              for attempt in 1 2 3; do
                [ "$attempt" -gt 1 ] && sleep 10
                result="$(curl --silent --show-error --max-time 20 --output /dev/null \
                  --write-out '%{http_code} %{redirect_url}' "$1")" || result="curl error"
                case "$result" in
                  302\ https://*.cloudflareaccess.com/*) return 0 ;;
                esac
              done
              echo "Cloudflare Access check failed for $1: $result" >&2
              exit 1
            }
            check https://ai.su.is/
            check https://ai.su.is/session
          '';
        };

        systemd.timers.opencode-web-access-check = mkIf (config.cockpit.webTunnelTokenFile != null) {
          description = "Periodically verify Cloudflare Access";
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnBootSec = "2m";
            OnUnitActiveSec = "5m";
            Unit = "opencode-web-access-check.service";
          };
        };
      };
    };
}
