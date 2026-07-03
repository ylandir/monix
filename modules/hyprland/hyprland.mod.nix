# The Hyprland desktop concern: compositor + session at the system level, the
# user's full Hyprland configuration at the home level. (nixpkgs Hyprland
# instead of the hyprwm/Hyprland git flake; option layer collapsed into
# concrete settings).
{
  flake.nixosModules.hyprland =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      inherit (lib.modules) mkIf;
    in
    {
      config = mkIf config.isDesktop {
        programs.hyprland.enable = true;

        # UWSM (Universal Wayland Session Manager) now owns the systemd
        # session lifecycle instead of the home-manager Hyprland module's own
        # hook (see the homeModules.hyprland aspect below). In this nixpkgs
        # pin, `withUWSM` by itself only flips `programs.uwsm.enable`; it does
        # NOT register Hyprland with UWSM or add a session entry (confirmed
        # by reading nixos/modules/programs/wayland/hyprland.nix: the
        # `withUWSM` mkIf block is just `{ programs.uwsm.enable = true; }`).
        programs.hyprland.withUWSM = true;

        # `programs.uwsm.waylandCompositors.<name>` (nixos/modules/programs/wayland/uwsm.nix,
        # `mk_uwsm_desktop_entry`) generates
        # `Exec=${uwsm} start -F -- ${binPath} ${extraArgs}`: everything after
        # `--` is an argument to the *compositor*, not to `uwsm start`, and the
        # module gives no way to inject flags before `--`. That entry (via
        # `binPath = start-hyprland`) is exactly what caused the bug: with no
        # `-D`/`--desktop-names` given to `uwsm start`, uwsm seeds
        # XDG_CURRENT_DESKTOP from the launched binary's own name
        # (`start-hyprland`), and its bundled quirk plugin
        # (uwsm-plugins/start_hyprland.sh -> quirks_hyprland) then *appends*
        # `:Hyprland` rather than replacing it, producing
        # "start-hyprland:Hyprland". Hyprland's own startup check
        # (src/Compositor.cpp, `performUserChecks`) does an exact-string
        # comparison against literal "Hyprland" (not a substring/prefix
        # check), so that combined value trips the "managed externally"
        # notification every session. There is no `waylandCompositors`
        # suboption (no `-D`, `desktopNames`, `extraFlags` before `--`, etc.)
        # to fix this from within the nixpkgs module, so this bypasses it
        # entirely and writes the wayland-sessions desktop entry directly,
        # passing `-D Hyprland` to `uwsm start` itself: that seeds
        # XDG_CURRENT_DESKTOP="Hyprland" up front, and the quirk plugin's own
        # `case "A:${XDG_CURRENT_DESKTOP}:Z" in *:Hyprland:*) true ;;` guard
        # then sees "Hyprland" already present and leaves it untouched — the
        # value Hyprland's check requires, verbatim.
        #
        # This also replaces (not supplements) the plain, non-UWSM "Hyprland"
        # entry that `programs.hyprland.enable` installs via
        # `services.displayManager.sessionPackages = [ cfg.package ]`
        # (nixos/modules/programs/wayland/hyprland.nix) — `mkForce` here drops
        # that entry so the greeter offers exactly one Hyprland session.
        services.displayManager.sessionPackages = lib.mkForce [
          (pkgs.writeTextFile {
            name = "hyprland-uwsm";
            text = ''
              [Desktop Entry]
              Name=Hyprland
              Comment=Hyprland compositor managed by UWSM
              Exec=${lib.getExe pkgs.uwsm} start -F -D Hyprland -- ${lib.getExe' pkgs.hyprland "start-hyprland"}
              Type=Application
            '';
            # Point at start-hyprland, not the raw Hyprland binary. Hyprland's
            # main() only clears its "started without start-hyprland" warning
            # when handed a valid `--watchdog-fd` (src/main.cpp: `watchdogOk =
            # watchdogFd > 0`); that fd is a pipe start-hyprland itself
            # creates and passes when it forks+execs Hyprland, so no env var
            # can substitute for it. start-hyprland is otherwise just a
            # crash-restart watchdog around Hyprland (start/src/core/Instance.cpp:
            # fork/exec loop, `while(true)` restart-on-unclean-exit) — it does
            # no systemd/target manipulation of its own, so nesting it inside
            # the uwsm-managed unit is safe. This matches upstream guidance:
            # the Hyprland wiki's Systemd-start page (linked from nixpkgs'
            # `programs.hyprland.withUWSM` description) and maintainer
            # fufexan (github.com/hyprwm/Hyprland/discussions/12661) both say
            # to launch `start-hyprland` under uwsm rather than the bare
            # binary; suppressing the warning via
            # `misc:disable_watchdog_warning` is called out there as the
            # less-recommended alternative.
            destination = "/share/wayland-sessions/hyprland-uwsm.desktop";
            derivationArgs = {
              # Mirrors nixpkgs' own `mk_uwsm_desktop_entry` passthru so
              # `services.displayManager.sessionPackages` can find the
              # session id this package provides.
              passthru.providedSessions = [ "hyprland-uwsm" ];
            };
          })
        ];

        hardware.graphics.enable = true;

        xdg.portal.enable = true;
        xdg.portal.extraPortals = [ pkgs.xdg-desktop-portal-gtk ];

        # greetd itself, and the session launch command (start-hyprland when
        # present, see the dms-greeter asset script), are configured by the
        # DankMaterialShell greeter module (see dank.mod.nix).

        # Secret storage for desktop applications, unlocked at greetd login.
        services.gnome.gnome-keyring.enable = true;
        security.pam.services.greetd.enableGnomeKeyring = true;
      };
    };

  # Written in Lua, not hyprlang. Hyprland deprecated hyprlang in favor of
  # Lua at 0.55 (nixpkgs currently ships 0.55.4) and states hyprlang will be
  # dropped "1-2 releases" after 0.55, with no fixed version given yet.
  # home-manager's hyprland module infers configType from home.stateVersion
  # (< 26.05 => hyprlang), so this is pinned explicitly rather than left
  # implicit — an unrelated future stateVersion bump must not silently
  # switch config generation. This has not been evaluated by `nix` or run
  # against a live Hyprland — neither exists in the environment this was
  # written in. Rebuild and test before trusting it.
  #
  # Every bind carries a `description`, which is not decorative: the DMS
  # keybinds overlay (SUPER+K, see the bind list below) reads these back at
  # runtime via `hyprctl binds -j`, which is the only reliable source of the
  # live bind list since Lua is executed, not parsed. Keep descriptions and
  # behavior in sync — nothing regenerates one from the other.
  #
  # Renames of note versus the prior hyprlang config, confirmed against
  # current docs while translating:
  #   - env vars: no more `general.env` list; each is its own `hl.env(k, v)`
  #     call.
  #   - `killactive` -> `hl.dsp.window.close()`.
  #   - `togglesplit` is no longer a dispatcher; it is a `layout` message:
  #     `hl.dsp.layout("togglesplit")`.
  #   - `pseudo` -> `hl.dsp.window.pseudo()`.
  #   - `togglefloating` -> `hl.dsp.window.float()`; `fullscreen` ->
  #     `hl.dsp.window.fullscreen({ mode = "fullscreen" })`.
  #   - `movefocus`/`swapwindow` -> `hl.dsp.focus({direction=...})` /
  #     `hl.dsp.window.swap({direction=...})`.
  #   - `workspace`/`movetoworkspace` -> `hl.dsp.focus({workspace=...})` /
  #     `hl.dsp.window.move({workspace=...})`. Relative selectors ("+1",
  #     "-1", "e+1") stay strings; absolute targets are plain ints.
  #   - `resizeactive` -> `hl.dsp.window.resize({x=,y=,relative=true})`.
  #   - `togglespecialworkspace` -> `hl.dsp.workspace.toggle_special(name)`.
  #   - `sendshortcut` -> `hl.dsp.send_shortcut({mods=,key=})`.
  #   - `bindm`/`bindel`/`bindl` collapse into one `bind` list; the old
  #     flag letters become an options table: `{mouse=true}`,
  #     `{locked=true, repeating=true}`, `{locked=true}`.
  #   - window-rule effect names changed: `nofocus` -> `no_focus`,
  #     `stayfocused` -> `stay_focused`, `suppressevent maximize` ->
  #     `suppress_event = "maximize"`. Match props: `floating` -> `float`,
  #     `pinned` -> `pin`.
  #   - `exec`/`exec-once` both fold into one `hl.on("hyprland.start", fn)`
  #     callback. This drops one piece of prior behavior: an old bare `exec`
  #     line in the source re-ran a restart-or-launch command on every config
  #     reload (`hyprctl reload`), not just at startup. No documented Lua
  #     event equivalent to "on config reload" was found — that specific
  #     behavior (a program auto-restarting when you edit and reload its own
  #     config) is not reproduced for anything started via the callback below.
  flake.homeModules.hyprland =
    {
      lib,
      osConfig,
      pkgs,
      ...
    }:
    let
      inherit (lib.modules) mkIf;
      inherit (lib.generators) mkLuaInline;
      inherit (lib.lists) concatMap range;
      inherit (lib.attrsets) recursiveUpdate;
      inherit (lib.meta) getExe getExe';

      # One `hl.bind(keys, dispatcher, opts)` call per list element.
      # `dispatcherLua` is raw Lua source (a `hl.dsp....(...)` expression);
      # `opts` merges over `{ description = ...; }`, so callers only need to
      # add flags (`locked`, `repeating`, `mouse`) that differ from none.
      mkBind =
        keys: dispatcherLua: description: opts:
        {
          _args = [
            keys
            (mkLuaInline dispatcherLua)
            (recursiveUpdate { inherit description; } opts)
          ];
        };

      # One `hl.env(key, value)` call per list element.
      mkEnv = key: value: { _args = [ key value ]; };
    in
    {
      config = mkIf osConfig.isDesktop {
        wayland.windowManager.hyprland = {
          enable = true;
          configType = "lua";

          # Deferred to the NixOS-level `programs.hyprland.enable` (see the
          # nixosModules.hyprland aspect above), which installs the
          # compositor and the Hyprland xdg-desktop-portal system-wide;
          # setting these to null avoids a second, HM-managed copy of each
          # package (see `wayland.windowManager.hyprland.package`'s
          # description: "Set this to null if you use the NixOS module to
          # install Hyprland.").
          package = null;
          portalPackage = null;

          # UWSM owns the systemd session now (see the NixOS-level
          # `programs.hyprland.withUWSM` / `programs.uwsm.waylandCompositors.hyprland`
          # in the nixosModules.hyprland aspect above): the "Hyprland (UWSM)"
          # session entry runs `uwsm start -F -- Hyprland`, which launches the
          # compositor inside `wayland-wm@Hyprland.service` and brings up
          # `graphical-session-pre.target` / `graphical-session.target` /
          # `xdg-desktop-autostart.target` itself. This module's own hook
          # (`hyprland-session.target`, BindsTo `graphical-session.target`)
          # would be redundant with — and would race — that, so it's disabled
          # here. Session env export is instead done by `uwsm finalize`, the
          # first autostart line below: WAYLAND_DISPLAY/DISPLAY are handled by
          # uwsm automatically, HYPRLAND_INSTANCE_SIGNATURE (needed by the DMS
          # logout button's `Hyprland.dispatch("exit")` IPC call),
          # HYPRCURSOR_THEME/SIZE and XCURSOR_THEME/SIZE are added
          # automatically by uwsm's built-in hyprland.sh plugin
          # (`UWSM_FINALIZE_VARNAMES`); XDG_CURRENT_DESKTOP, XDG_SESSION_TYPE
          # and XDG_SESSION_ID are passed explicitly to `uwsm finalize` to
          # preserve this module's prior variable-import behavior (uwsm
          # finalize silently skips undefined vars, so this is safe even if
          # one of them isn't set).
          systemd.enable = false;

          settings = {
            env = [
              (mkEnv "GDK_SCALE" "2")
              (mkEnv "XCURSOR_SIZE" "24")
              (mkEnv "HYPRCURSOR_SIZE" "24")
              (mkEnv "XCURSOR_THEME" "Adwaita")
              (mkEnv "HYPRCURSOR_THEME" "Adwaita")
              (mkEnv "GDK_BACKEND" "wayland")
              (mkEnv "QT_QPA_PLATFORM" "wayland")
              (mkEnv "SDL_VIDEODRIVER" "wayland")
              (mkEnv "MOZ_ENABLE_WAYLAND" "1")
              (mkEnv "ELECTRON_OZONE_PLATFORM_HINT" "wayland")
              (mkEnv "OZONE_PLATFORM" "wayland")
              (mkEnv "XDG_DATA_DIRS" "$XDG_DATA_DIRS:/etc/profiles/per-user/$USER/share:/run/current-system/sw/share")
              (mkEnv "EDITOR" "nvim")
              (mkEnv "GTK_THEME" "Adwaita:dark")
            ];

            # CORE CONFIG — one `hl.config({...})` call covering every category.
            config = {
              general = {
                gaps_in = 0;
                gaps_out = 0;
                border_size = 2;

                resize_on_border = false;
                allow_tearing = false;
                layout = "dwindle";
              };

              decoration = {
                rounding = 2;

                shadow.enabled = false;

                blur = {
                  enabled = true;
                  size = 3;
                  passes = 1;
                  vibrancy = 0.1696;
                };
              };

              animations.enabled = false;

              input = {
                kb_layout = "us";
                kb_options = "compose:caps";

                follow_mouse = 1;
                sensitivity = 0;

                touchpad = {
                  natural_scroll = false;
                  clickfinger_behavior = true;
                };
              };

              dwindle = {
                preserve_split = true;
                force_split = 2;
              };

              master.new_status = "master";

              misc = {
                disable_hyprland_logo = true;
                disable_splash_rendering = true;
              };

              cursor = {
                inactive_timeout = 5;
              };

              xwayland.force_zero_scaling = true;

              ecosystem.no_update_news = true;
            };

            # GESTURES — one `hl.gesture({...})` call per list element.
            gesture = [
              {
                fingers = 3;
                direction = "horizontal";
                action = "workspace";
              }
              {
                fingers = 4;
                direction = "swipe";
                action = "resize";
              }
              {
                fingers = 3;
                direction = "pinchout";
                action = "float";
                mode = "float";
              }
              {
                fingers = 4;
                direction = "pinchout";
                action = "float";
                mode = "float";
              }
              {
                fingers = 3;
                direction = "pinchin";
                action = "float";
                mode = "tile";
              }
              {
                fingers = 4;
                direction = "pinchin";
                action = "float";
                mode = "tile";
              }
              {
                fingers = 3;
                direction = "swipe";
                mods = "SUPER";
                action = "move";
              }
            ];

            # WINDOW RULES — one `hl.window_rule({...})` call per element.
            window_rule = [
              {
                match.class = ".*";
                suppress_event = "maximize";
              }
              {
                match.class = "^(org.pulseaudio.pavucontrol|blueberry.py)$";
                float = true;
              }
              {
                match.class = "^(steam)$";
                float = true;
              }
              {
                match.class = ".*";
                opacity = "1 0.9";
              }
              {
                match.class = "brave-browser";
                opacity = "1 1";
              }
              {
                match.class = "^(steam)$";
                opacity = "1 1";
              }
              {
                # Fix some dragging issues with XWayland.
                match = {
                  class = "^$";
                  title = "^$";
                  xwayland = true;
                  float = true;
                  fullscreen = false;
                  pin = false;
                };
                no_focus = true;
              }
            ];

            # LAYER RULES.
            layer_rule = [
              {
                match.namespace = "^(dms)$";
                no_anim = true;
              }
            ];

            # AUTOSTART — see the module-level comment for the dropped
            # reload-restart behavior. dms/ghostty startup are not done here:
            # they're handled by each unit's own
            # `Install.WantedBy = graphical-session.target` (see
            # ghostty.mod.nix, dank.mod.nix), which UWSM now brings up (see
            # `wayland.windowManager.hyprland.systemd` above).
            #
            # `uwsm finalize` MUST run first, and only once
            # `HYPRLAND_INSTANCE_SIGNATURE` etc. actually exist — it exports
            # session vars to the systemd/D-Bus activation environment and
            # signals `wayland-wm@Hyprland.service` ready, unblocking
            # graphical-session.target and everything WantedBy it.
            #
            # Long-running autostarts are wrapped in `uwsm app --`, per uwsm
            # convention, so they run as their own transient systemd scopes
            # under the session (tracked/cleaned up by systemd) rather than as
            # bare children of Hyprland. Keybind execs are deliberately left
            # unwrapped (see the bind list below) — `uwsm app` is for
            # long-lived autostarts, not one-shot interactive launches.
            #
            # hyprsunset is dropped in favor of DMS's built-in night mode
            # (DisplayService.qml's `wayland.gamma.*` calls), which talks
            # directly to the compositor over the `wlr-gamma-control-unstable-v1`
            # Wayland protocol from the `dms` daemon — no external process,
            # and Hyprland natively implements that protocol.
            on = {
              _args = [
                "hyprland.start"
                (mkLuaInline ''
                  function()
                    hl.exec_cmd("${getExe pkgs.uwsm} finalize XDG_CURRENT_DESKTOP XDG_SESSION_TYPE XDG_SESSION_ID")
                    hl.exec_cmd("${getExe pkgs.uwsm} app -- ${getExe pkgs.wl-clip-persist} --clipboard regular")
                    hl.exec_cmd("${getExe pkgs.uwsm} app -- ${getExe' pkgs.wl-clipboard "wl-paste"} --watch ${getExe pkgs.cliphist} store")
                  end
                '')
              ];
            };

            # BINDINGS
            bind =
              [
                (mkBind "SUPER + RETURN" ''hl.dsp.exec_cmd("${getExe pkgs.ghostty}")'' "Open terminal" { })
                (mkBind "SUPER + BACKSPACE" ''hl.dsp.exec_cmd("dms ipc call powermenu toggle")'' "Power menu" { })
                (mkBind "SUPER + SLASH" ''hl.dsp.exec_cmd("${getExe pkgs.keepassxc}")'' "Open password manager" { })
                (mkBind "SUPER + C" ''hl.dsp.send_shortcut({ mods = "CTRL", key = "Insert" })''
                  "Copy (send Ctrl+Insert to focused window)"
                  { }
                )
                (mkBind "SUPER + D" ''hl.dsp.exec_cmd("dms ipc call spotlight toggle")''
                  "App launcher"
                  { }
                )
                (mkBind "SUPER + E" ''hl.dsp.exec_cmd("thunderbird")'' "Open email" { })
                (mkBind "SUPER + M" ''hl.dsp.exec_cmd("spotify")'' "Open music" { })
                (mkBind "SUPER + N" ''hl.dsp.exec_cmd("${getExe pkgs.ghostty} -e nvim")'' "Open editor" { })
                (mkBind "SUPER + SHIFT + N" ''hl.dsp.exec_cmd("${getExe pkgs.ghostty} -e newsboat")''
                  "Open RSS reader"
                  { }
                )
                (mkBind "SUPER + R" ''hl.dsp.exec_cmd("${getExe pkgs.kdePackages.dolphin} --new-window")''
                  "Open file manager"
                  { }
                )
                (mkBind "SUPER + SHIFT + R" ''hl.dsp.exec_cmd("${getExe pkgs.ghostty} -e btop")''
                  "Open system monitor"
                  { }
                )
                (mkBind "SUPER + S" ''hl.dsp.exec_cmd("signal-desktop")'' "Open messenger" { })
                (mkBind "SUPER + V" ''hl.dsp.send_shortcut({ mods = "SHIFT", key = "Insert" })''
                  "Paste (send Shift+Insert to focused window)"
                  { }
                )
                (mkBind "SUPER + X" ''hl.dsp.send_shortcut({ mods = "CTRL", key = "X" })''
                  "Send Ctrl+X to focused window"
                  { }
                )
                (mkBind "SUPER + W"
                  ''hl.dsp.exec_cmd("${getExe pkgs.brave} --new-window --ozone-platform=wayland")''
                  "Open browser"
                  { }
                )

                (mkBind "SUPER + SHIFT + SPACE" ''hl.dsp.exec_cmd("dms ipc call bar toggle index 0")''
                  "Toggle bar"
                  { }
                )

                (mkBind "SUPER + Q" ''hl.dsp.window.close()'' "Close window" { })

                (mkBind "SUPER + ESCAPE" ''hl.dsp.exec_cmd("dms ipc call lock lock")'' "Lock screen" { })
                (mkBind "SUPER + SHIFT + ESCAPE" ''hl.dsp.exit()'' "Exit Hyprland" { })
                (mkBind "SUPER + CTRL + ESCAPE" ''hl.dsp.exec_cmd("reboot")'' "Reboot" { })
                (mkBind "SUPER + SHIFT + CTRL + ESCAPE" ''hl.dsp.exec_cmd("systemctl poweroff")'' "Power off" { })
                (mkBind "SUPER + K" ''hl.dsp.exec_cmd("dms ipc call keybinds toggle hyprland")''
                  "Show keybindings"
                  { }
                )
                (mkBind "SUPER + I" ''hl.dsp.exec_cmd("dms ipc call inhibit toggle")'' "Toggle idle inhibit" { })

                (mkBind "SUPER + J" ''hl.dsp.layout("togglesplit")'' "Toggle split direction" { })
                (mkBind "SUPER + P" ''hl.dsp.window.pseudo()'' "Toggle pseudotile" { })
                (mkBind "SUPER + SHIFT + F" ''hl.dsp.window.float()'' "Toggle floating" { })
                (mkBind "SUPER + F" ''hl.dsp.window.fullscreen({ mode = "fullscreen" })'' "Toggle fullscreen" { })

                (mkBind "SUPER + LEFT" ''hl.dsp.focus({ direction = "l" })'' "Focus window left" { })
                (mkBind "SUPER + RIGHT" ''hl.dsp.focus({ direction = "r" })'' "Focus window right" { })
                (mkBind "SUPER + UP" ''hl.dsp.focus({ direction = "u" })'' "Focus window up" { })
                (mkBind "SUPER + DOWN" ''hl.dsp.focus({ direction = "d" })'' "Focus window down" { })

                (mkBind "SUPER + COMMA" ''hl.dsp.focus({ workspace = "-1" })'' "Previous workspace" { })
                (mkBind "SUPER + PERIOD" ''hl.dsp.focus({ workspace = "+1" })'' "Next workspace" { })

                (mkBind "SUPER + SHIFT + LEFT" ''hl.dsp.window.swap({ direction = "l" })'' "Swap window left" { })
                (mkBind "SUPER + SHIFT + RIGHT" ''hl.dsp.window.swap({ direction = "r" })'' "Swap window right" { })
                (mkBind "SUPER + SHIFT + UP" ''hl.dsp.window.swap({ direction = "u" })'' "Swap window up" { })
                (mkBind "SUPER + SHIFT + DOWN" ''hl.dsp.window.swap({ direction = "d" })'' "Swap window down" { })

                (mkBind "SUPER + MINUS" ''hl.dsp.window.resize({ x = -100, y = 0, relative = true })''
                  "Shrink window width"
                  { }
                )
                (mkBind "SUPER + EQUAL" ''hl.dsp.window.resize({ x = 100, y = 0, relative = true })''
                  "Grow window width"
                  { }
                )
                (mkBind "SUPER + SHIFT + MINUS" ''hl.dsp.window.resize({ x = 0, y = -100, relative = true })''
                  "Shrink window height"
                  { }
                )
                (mkBind "SUPER + SHIFT + EQUAL" ''hl.dsp.window.resize({ x = 0, y = 100, relative = true })''
                  "Grow window height"
                  { }
                )

                (mkBind "SUPER + mouse_down" ''hl.dsp.focus({ workspace = "e+1" })'' "Next open workspace" { })
                (mkBind "SUPER + mouse_up" ''hl.dsp.focus({ workspace = "e-1" })'' "Previous open workspace" { })

                # On SUPER+U: SUPER+S collides with $messenger.
                (mkBind "SUPER + U" ''hl.dsp.workspace.toggle_special("magic")'' "Toggle special workspace" { })
                (mkBind "SUPER + SHIFT + U" ''hl.dsp.window.move({ workspace = "special:magic" })''
                  "Move window to special workspace"
                  { }
                )

                (mkBind "PRINT" ''hl.dsp.exec_cmd("${getExe pkgs.hyprshot} -m region")''
                  "Screenshot region"
                  { }
                )
                (mkBind "SHIFT + PRINT" ''hl.dsp.exec_cmd("${getExe pkgs.hyprshot} -m window")''
                  "Screenshot window"
                  { }
                )
                (mkBind "CTRL + PRINT" ''hl.dsp.exec_cmd("${getExe pkgs.hyprshot} -m output")''
                  "Screenshot output"
                  { }
                )
                (mkBind "SUPER + PRINT" ''hl.dsp.exec_cmd("${getExe pkgs.hyprpicker} -a")'' "Pick color" { })

                (mkBind "CTRL + SUPER + V" ''hl.dsp.exec_cmd("dms ipc call clipboard toggle")''
                  "Clipboard history"
                  { }
                )

                (mkBind "SUPER + mouse:272" ''hl.dsp.window.drag()'' "Move window" { mouse = true; })
                (mkBind "SUPER + mouse:273" ''hl.dsp.window.resize()'' "Resize window" { mouse = true; })

                (mkBind "XF86AudioRaiseVolume" ''hl.dsp.exec_cmd("wpctl set-volume -l 1 @DEFAULT_AUDIO_SINK@ 5%+")''
                  "Volume up"
                  {
                    locked = true;
                    repeating = true;
                  }
                )
                (mkBind "XF86AudioLowerVolume" ''hl.dsp.exec_cmd("wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-")''
                  "Volume down"
                  {
                    locked = true;
                    repeating = true;
                  }
                )
                (mkBind "XF86AudioMute" ''hl.dsp.exec_cmd("wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle")''
                  "Mute"
                  {
                    locked = true;
                    repeating = true;
                  }
                )
                (mkBind "XF86AudioMicMute" ''hl.dsp.exec_cmd("wpctl set-mute @DEFAULT_AUDIO_SOURCE@ toggle")''
                  "Mic mute"
                  {
                    locked = true;
                    repeating = true;
                  }
                )
                (mkBind "XF86MonBrightnessUp" ''hl.dsp.exec_cmd("${getExe pkgs.brightnessctl} set 655+")''
                  "Brightness up"
                  {
                    locked = true;
                    repeating = true;
                  }
                )
                (mkBind "XF86MonBrightnessDown" ''hl.dsp.exec_cmd("${getExe pkgs.brightnessctl} set 655-")''
                  "Brightness down"
                  {
                    locked = true;
                    repeating = true;
                  }
                )

                (mkBind "XF86AudioNext" ''hl.dsp.exec_cmd("${getExe pkgs.playerctl} next")''
                  "Next track"
                  { locked = true; }
                )
                (mkBind "XF86AudioPause" ''hl.dsp.exec_cmd("${getExe pkgs.playerctl} play-pause")''
                  "Play/pause"
                  { locked = true; }
                )
                (mkBind "XF86AudioPlay" ''hl.dsp.exec_cmd("${getExe pkgs.playerctl} play-pause")''
                  "Play/pause"
                  { locked = true; }
                )
                (mkBind "XF86AudioPrev" ''hl.dsp.exec_cmd("${getExe pkgs.playerctl} previous")''
                  "Previous track"
                  { locked = true; }
                )
              ]
              # Switch to / move to workspaces 1-9, generated to cut
              # transcription risk on a repetitive block.
              ++ (
                concatMap
                  (
                    i:
                    let
                      n = toString i;
                    in
                    [
                      (mkBind "SUPER + ${n}" ''hl.dsp.focus({ workspace = ${n} })'' "Switch to workspace ${n}" { })
                      (mkBind "SUPER + SHIFT + ${n}" ''hl.dsp.window.move({ workspace = ${n} })''
                        "Move window to workspace ${n}"
                        { }
                      )
                    ]
                  )
                  (range 1 9)
              )
              ++ [
                (mkBind "SUPER + 0" ''hl.dsp.focus({ workspace = 10 })'' "Switch to workspace 10" { })
                (mkBind "SUPER + SHIFT + 0" ''hl.dsp.window.move({ workspace = 10 })''
                  "Move window to workspace 10"
                  { }
                )
              ];
          };
        };
      };
    };
}
