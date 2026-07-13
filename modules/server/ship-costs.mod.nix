# ship-costs — the ledger. Answers "what would this month's AI usage have
# cost at API rates?" across every pool the ship spends from:
#
#   claude      cockpit Claude Code transcripts (~/.claude/projects) +
#               fleet drone usage.json archives (tasks/done|failed)
#   chatgpt     cockpit codex sessions (~/.codex/sessions) + opencode
#               messages with providerID=openai + codex drones
#   openrouter  exact spend via the API when a key is wired (metered pool);
#               otherwise whatever opencode recorded per message
#   local       llama-swap models — counted, priced $0
#
# Token counts are real (recorded by each tool); the USD figures are
# API-EQUIVALENT — what identical usage would bill at pay-per-token rates.
# Subscriptions bill flat, so this is an opportunity-cost lens, not an
# invoice. Scope: only what ran on this ship. claude.ai / chatgpt.com app
# chats leave no local artifacts and are invisible here (the Claude plan's
# limit gauge in-app includes them; nothing exposes their tokens).
#
# PRICING TABLE (in the script, $/MTok) — update when vendors reprice:
# verified 2026-07-12: Fable 10/50, Opus 5/25, Sonnet 3/15, Haiku 1/5
# (cache read 0.1x input, cache write 1.25x/5m 2x/1h); GPT-5.6 Sol and
# GPT-5.5 5/30 (cached in 0.5), Terra 2.5/15, Luna 1/6.
#
# Codex sessions also carry the ChatGPT plan's live rate-limit windows —
# the only sub-limit gauge available on disk — shown with its staleness.
{
  flake.nixosModules.ship-costs =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      inherit (lib.modules) mkIf;
      inherit (lib.options) mkEnableOption mkOption;
      inherit (lib) types;

      cfg = config.shipCosts;

      shipCosts = pkgs.writeScriptBin "ship-costs" ''
        #!${pkgs.python3}/bin/python3
        import datetime as dt
        import glob
        import json
        import os
        import sqlite3
        import sys
        import urllib.request

        HOME = os.path.expanduser("~")
        CLAUDE_DIR = os.path.join(HOME, ".claude", "projects")
        CODEX_DIR = os.path.join(HOME, ".codex", "sessions")
        OPENCODE_GLOB = os.path.join(HOME, ".local", "share", "opencode", "*.db")
        FLEET_GLOBS = [
            "/var/lib/agents/tasks/done/*/usage.json",
            "/var/lib/agents/tasks/failed/*/usage.json",
        ]
        OPENROUTER_KEY_FILE = ${if cfg.openrouterKeyFile != null then ''"${cfg.openrouterKeyFile}"'' else "None"}

        NOW = dt.datetime.now(dt.timezone.utc)
        MTD = NOW.replace(day=1, hour=0, minute=0, second=0, microsecond=0)
        D30 = NOW - dt.timedelta(days=30)

        # ($/MTok) prefix-matched, first hit wins: (in, out, cache_read, cache_write_5m, cache_write_1h)
        PRICING = [
            ("claude-fable-5", (10, 50, 1.0, 12.5, 20)),
            ("claude-opus", (5, 25, 0.5, 6.25, 10)),
            ("claude-sonnet", (3, 15, 0.3, 3.75, 6)),
            ("claude-haiku", (1, 5, 0.1, 1.25, 2)),
            ("gpt-5.6-sol", (5, 30, 0.5, 0, 0)),
            ("gpt-5.5", (5, 30, 0.5, 0, 0)),
            ("gpt-5.6-terra", (2.5, 15, 0.25, 0, 0)),
            ("gpt-5.4", (2.5, 15, 0.25, 0, 0)),
            ("gpt-5.6-luna", (1, 6, 0.1, 0, 0)),
            ("gpt-", (5, 30, 0.5, 0, 0)),  # unknown gpt: price like Sol, flagged
        ]


        def rates(model):
            m = model.split("/")[-1]
            for prefix, r in PRICING:
                if m.startswith(prefix):
                    return r
            return None


        def pool_of(model):
            m = model.lower()
            if m.startswith("local/"):
                return "local"
            if m.startswith("openrouter/"):
                return "openrouter"
            if "claude" in m:
                return "claude"
            if "gpt" in m or m.startswith("openai/"):
                return "chatgpt"
            return "other"


        # events: (ts, model, source, {in, out, cr, cw5, cw1}) — cw5/cw1 are
        # Anthropic 5m/1h cache writes; non-Anthropic cache reads land in cr.
        def ev(ts, model, source, i=0, o=0, cr=0, cw5=0, cw1=0):
            return (ts, model, source, {"in": i, "out": o, "cr": cr, "cw5": cw5, "cw1": cw1})


        def parse_ts(s):
            return dt.datetime.fromisoformat(s.replace("Z", "+00:00"))


        def iter_claude():
            seen = set()
            for path in glob.glob(os.path.join(CLAUDE_DIR, "**", "*.jsonl"), recursive=True):
                try:
                    fh = open(path, encoding="utf-8", errors="replace")
                except OSError:
                    continue
                with fh:
                    for line in fh:
                        try:
                            e = json.loads(line)
                        except ValueError:
                            continue
                        if e.get("type") != "assistant":
                            continue
                        msg = e.get("message") or {}
                        u = msg.get("usage")
                        if not u:
                            continue
                        key = (e.get("requestId"), msg.get("id"))
                        if key in seen:
                            continue
                        seen.add(key)
                        cc = u.get("cache_creation") or {}
                        cw5 = cc.get("ephemeral_5m_input_tokens")
                        cw1 = cc.get("ephemeral_1h_input_tokens", 0)
                        if cw5 is None:  # older entries: only the total, price as 5m
                            cw5 = u.get("cache_creation_input_tokens", 0)
                            cw1 = 0
                        try:
                            ts = parse_ts(e["timestamp"])
                        except (KeyError, ValueError):
                            continue
                        yield ev(ts, msg.get("model") or "unknown", "cockpit claude",
                                 u.get("input_tokens", 0), u.get("output_tokens", 0),
                                 u.get("cache_read_input_tokens", 0), cw5, cw1)


        def iter_codex():
            # total_token_usage is cumulative per session file: use each
            # file's final value. Also surfaces the newest rate-limit gauge.
            gauge = {"ts": None}
            for path in glob.glob(os.path.join(CODEX_DIR, "**", "*.jsonl"), recursive=True):
                model, total, ts = "unknown", None, None
                try:
                    fh = open(path, encoding="utf-8", errors="replace")
                except OSError:
                    continue
                with fh:
                    for line in fh:
                        try:
                            e = json.loads(line)
                        except ValueError:
                            continue
                        p = e.get("payload") or {}
                        if e.get("type") == "turn_context" and p.get("model"):
                            model = p["model"]
                        elif e.get("type") == "event_msg" and p.get("type") == "token_count":
                            info = p.get("info") or {}
                            if info.get("total_token_usage"):
                                total = info["total_token_usage"]
                                try:
                                    ts = parse_ts(e["timestamp"])
                                except (KeyError, ValueError):
                                    pass
                            rl = p.get("rate_limits")
                            if rl and ts and (gauge["ts"] is None or ts > gauge["ts"]):
                                gauge.update({"ts": ts, "rl": rl})
                if total and ts:
                    cached = total.get("cached_input_tokens", 0)
                    yield ev(ts, model, "cockpit codex",
                             total.get("input_tokens", 0) - cached,
                             total.get("output_tokens", 0), cached)
            iter_codex.gauge = gauge


        iter_codex.gauge = {"ts": None}


        def iter_opencode():
            for path in glob.glob(OPENCODE_GLOB):
                try:
                    db = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
                    rows = db.execute("select data from message").fetchall()
                    db.close()
                except sqlite3.Error:
                    continue
                for (data,) in rows:
                    try:
                        m = json.loads(data)
                    except ValueError:
                        continue
                    if m.get("role") != "assistant" or not m.get("tokens"):
                        continue
                    t = m["tokens"]
                    created = (m.get("time") or {}).get("created")
                    if not created:
                        continue
                    ts = dt.datetime.fromtimestamp(created / 1000, dt.timezone.utc)
                    model = f"{m.get('providerID', '?')}/{m.get('modelID', 'unknown')}"
                    cache = t.get("cache") or {}
                    e = ev(ts, model, "cockpit opencode",
                           t.get("input", 0),
                           t.get("output", 0) + t.get("reasoning", 0),
                           cache.get("read", 0), cache.get("write", 0))
                    e[3]["cost"] = m.get("cost") or 0
                    yield e


        def iter_fleet():
            for pattern in FLEET_GLOBS:
                for path in glob.glob(pattern):
                    try:
                        with open(path, encoding="utf-8") as fh:
                            u = json.load(fh)
                        ts = dt.datetime.fromtimestamp(os.path.getmtime(path), dt.timezone.utc)
                    except (OSError, ValueError):
                        continue
                    yield ev(ts, u.get("model", "unknown"), f"drone {u.get('executor', '?')}",
                             u.get("input_tokens", 0), u.get("output_tokens", 0),
                             u.get("cache_read_tokens", 0), u.get("cache_creation_tokens", 0))


        def cost_usd(model, t):
            r = rates(model)
            if pool_of(model) == "local":
                return 0.0
            if r is None:
                return t.get("cost", 0) or 0.0  # opencode metered rows carry real cost
            i, o, cr, cw5, cw1 = r
            usd = (t["in"] * i + t["out"] * o + t["cr"] * cr
                   + t["cw5"] * cw5 + t["cw1"] * cw1) / 1e6
            return usd + (t.get("cost", 0) or 0)


        def openrouter_exact():
            if not OPENROUTER_KEY_FILE:
                return None
            try:
                with open(OPENROUTER_KEY_FILE, encoding="utf-8") as fh:
                    key = fh.read().strip().split("=")[-1]
            except OSError:
                return None
            req = urllib.request.Request(
                "https://openrouter.ai/api/v1/activity",
                headers={"Authorization": f"Bearer {key}"})
            try:
                with urllib.request.urlopen(req, timeout=15) as resp:
                    return json.load(resp).get("data")
            except Exception:
                return None


        def main():
            windows = {"mtd": {}, "d30": {}}
            for it in (iter_claude, iter_codex, iter_opencode, iter_fleet):
                for ts, model, source, t in it():
                    if ts < D30 and ts < MTD:
                        continue
                    for name, start in (("mtd", MTD), ("d30", D30)):
                        if ts < start:
                            continue
                        key = (pool_of(model), model, source)
                        agg = windows[name].setdefault(
                            key, {"in": 0, "out": 0, "cr": 0, "cw5": 0, "cw1": 0, "cost": 0})
                        for k in ("in", "out", "cr", "cw5", "cw1"):
                            agg[k] += t[k]
                        agg["cost"] += t.get("cost", 0) or 0

            print("SHIP COSTS — API-equivalent spend (subs bill flat; this is what the")
            print("same usage would cost at API rates). Ship-side usage only; app chats")
            print(f"are invisible. Windows: MTD since {MTD:%b %d}, rolling 30d.\n")

            d30 = windows["d30"]
            order = {"claude": 0, "chatgpt": 1, "openrouter": 2, "local": 3, "other": 4}
            header = f"{'POOL':<11}{'MODEL':<28}{'SOURCE':<18}{'TOK(M)':>8}{'MTD $':>9}{'30D $':>9}"
            print(header)
            print("-" * len(header))
            totals = {"mtd": {}, "d30": {}}
            for key in sorted(d30, key=lambda k: (order.get(k[0], 9), k[1], k[2])):
                pool, model, source = key
                t30 = d30[key]
                tmtd = windows["mtd"].get(key)
                usd30 = cost_usd(model, t30)
                usdmtd = cost_usd(model, tmtd) if tmtd else 0.0
                totals["d30"][pool] = totals["d30"].get(pool, 0) + usd30
                totals["mtd"][pool] = totals["mtd"].get(pool, 0) + usdmtd
                mtok = (t30["in"] + t30["out"] + t30["cr"] + t30["cw5"] + t30["cw1"]) / 1e6
                star = "" if rates(model) or pool == "local" else " *"
                print(f"{pool:<11}{model[:27]:<28}{source:<18}{mtok:>8.1f}"
                      f"{usdmtd:>9.2f}{usd30:>9.2f}{star}")
            print("-" * len(header))
            for pool in sorted(totals["d30"], key=lambda p: order.get(p, 9)):
                pad = " " * 49  # MODEL(28)+SOURCE(18)+TOK(8) minus len("TOTAL")
                print(f"{pool:<11}TOTAL{pad}"
                      f"{totals['mtd'].get(pool, 0):>9.2f}{totals['d30'][pool]:>9.2f}")
            grand = sum(totals["d30"].values())
            grandm = sum(totals["mtd"].values())
            pad = " " * 54  # MODEL(28)+SOURCE(18)+TOK(8)
            print(f"{'ALL':<11}{pad}{grandm:>9.2f}{grand:>9.2f}")
            print("\n* no pricing entry — token counts real, cost not estimated")

            exact = openrouter_exact()
            if exact is not None:
                print("\nOPENROUTER (exact, via API):")
                by_model = {}
                for row in exact:
                    d = row.get("date", "")
                    try:
                        rts = dt.datetime.fromisoformat(d).replace(tzinfo=dt.timezone.utc)
                    except ValueError:
                        continue
                    if rts < D30:
                        continue
                    by_model.setdefault(row.get("model", "?"), [0, 0])
                    by_model[row["model"]][0] += row.get("usage", 0)
                    if rts >= MTD:
                        by_model[row["model"]][1] += row.get("usage", 0)
                for model, (u30, umtd) in sorted(by_model.items()):
                    print(f"  {model:<40}{umtd:>9.2f}{u30:>9.2f}")
            elif OPENROUTER_KEY_FILE:
                print("\nOPENROUTER: key configured but API query failed (see above table")
                print("for opencode-recorded costs).")

            g = iter_codex.gauge
            print()
            if g.get("ts"):
                rl = g.get("rl") or {}
                age = NOW - g["ts"]
                parts = []
                for name in ("primary", "secondary"):
                    w = rl.get(name)
                    if w:
                        wm = w.get("window_minutes", 0)
                        label = f"{wm // 60}h" if wm < 10080 else f"{wm // 1440}d"
                        parts.append(f"{label} window {w.get('used_percent', '?')}% used")
                plan = rl.get("plan_type", "?")
                print(f"CHATGPT PLAN ({plan}): " + "; ".join(parts)
                      + f"  [as of last codex turn, {age.total_seconds() / 3600:.1f}h ago]")
            else:
                print("CHATGPT PLAN: no codex sessions found for a limit gauge")
            print("CLAUDE PLAN: account-wide window not exposed on disk — check /usage")
            print("in Claude Code (that gauge includes app chats; this ledger doesn't).")


        if __name__ == "__main__":
            sys.exit(main())
      '';
    in
    {
      options.shipCosts = {
        enable = mkEnableOption "the ship-costs usage/cost ledger CLI";

        openrouterKeyFile = mkOption {
          type = types.nullOr types.path;
          default = null;
          description = ''
            File containing an OpenRouter key (a management key from
            Settings → Management Keys is preferred; read-only, free) for
            exact per-model spend via the activity API. Must be readable
            by whoever runs ship-costs. null = skip the API section.
          '';
        };
      };

      config = mkIf cfg.enable {
        environment.systemPackages = [ shipCosts ];
      };
    };
}
