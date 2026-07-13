"""remy — the family's household chat bot.

One bot, two rooms, room-scoped skills:

  - "Household" (created by the bot on first start, family invited):
    tasks with due dates and named lists in plain language ("we need to
    take the car in by Friday", "add milk and eggs to shopping"), plus a
    morning plan (07:00) and evening report (19:00) with week-ahead
    sections on Sunday evening and Monday morning, folding in the family
    calendar (calendar.json, written by the separate remy-calendar-sync
    unit — this process never leaves loopback).

  - "Budget" (the pre-existing room; remy absorbed budgetbot 2026-07-13):
    the complete budgetbot skill set against the same ledger at
    /var/lib/budgetbot/budget.db — purchases in plain language, edits,
    soft deletes, queries, charts, the Sunday check-in and stale-entry
    nag. Data and behavior unchanged; only the account answering did.

Design constraints (inherited from budgetbot):
  - Chat text is UNTRUSTED input. The LLM only ever classifies it into a
    fixed per-room intent schema; SQL is always parameterized from typed
    fields; there is no path from message text to shell, SQL, or Matrix
    admin.
  - Idempotent event handling: every processed Matrix event id is recorded
    and skipped on re-delivery, so restarts/replays never double-file.
  - No cloud calls: parsing runs on the ship's own GPU.
"""

import asyncio
import io
import json
import logging
import os
import re
import sqlite3
import subprocess
import time
from datetime import date, datetime, timedelta
from zoneinfo import ZoneInfo

import requests
from nio import AsyncClient, InviteMemberEvent, RoomMessageText

log = logging.getLogger("remy")
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")

HS_URL = os.environ["BOT_HS_URL"]
USER_ID = os.environ["MATRIX_USER"]
PASSWORD = os.environ["MATRIX_PASSWORD"]
INVITE_USERS = [u for u in os.environ.get("BOT_INVITE_USERS", "").split(",") if u]
ROOM_NAME = os.environ.get("BOT_ROOM_NAME", "Household")
BUDGET_ROOM_ID = os.environ.get("BOT_BUDGET_ROOM_ID", "")
LLM_URL = os.environ.get("LLM_URL", "http://127.0.0.1:8091/v1/chat/completions")
LLM_MODEL = os.environ.get("LLM_MODEL", "qwen3.6-35b-a3b")
DB_PATH = os.environ.get("BOT_DB", "/var/lib/remy/home.db")
BUDGET_DB_PATH = os.environ.get("BOT_BUDGET_DB", "/var/lib/budgetbot/budget.db")
CAL_PATH = os.environ.get("BOT_CALENDAR_JSON", "/var/lib/remy/calendar.json")
TZ = ZoneInfo(os.environ.get("BOT_TZ", "America/New_York"))
MORNING = os.environ.get("BOT_MORNING", "07:00")
EVENING = os.environ.get("BOT_EVENING", "19:00")
BUDGET_REMIND_HOUR = int(os.environ.get("BOT_BUDGET_REMIND_HOUR", "18"))
BUDGET_STALE_DAYS = int(os.environ.get("BOT_BUDGET_STALE_DAYS", "3"))

DEFAULT_CATEGORIES = [
    "groceries", "dining", "transport", "household", "health",
    "entertainment", "utilities", "clothing", "gifts", "travel", "other",
]

START_MS = int(time.time() * 1000)


# ---------------------------------------------------------------- databases

def connect(path):
    # check_same_thread=False: llm parsing reads via asyncio.to_thread while
    # the event loop owns writes; CPython's sqlite3 is built in serialized
    # threading mode, so sharing one connection across threads is safe.
    db = sqlite3.connect(path, check_same_thread=False)
    db.row_factory = sqlite3.Row
    return db


def home_db():
    db = connect(DB_PATH)
    db.executescript("""
        CREATE TABLE IF NOT EXISTS task(
            id INTEGER PRIMARY KEY,
            title TEXT NOT NULL,
            due TEXT NOT NULL DEFAULT '',   -- ISO yyyy-mm-dd, '' = undated
            created_by TEXT NOT NULL,
            created_ts INTEGER NOT NULL,
            done_ts INTEGER,                -- NULL = open
            done_by TEXT NOT NULL DEFAULT '',
            deleted INTEGER NOT NULL DEFAULT 0  -- soft delete: recoverable
        );
        CREATE TABLE IF NOT EXISTS item(
            id INTEGER PRIMARY KEY,
            list_name TEXT NOT NULL,
            name TEXT NOT NULL,
            added_by TEXT NOT NULL,
            added_ts INTEGER NOT NULL,
            done_ts INTEGER,                -- NULL = still needed
            deleted INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS processed(event_id TEXT PRIMARY KEY, ts INTEGER);
        CREATE TABLE IF NOT EXISTS meta(k TEXT PRIMARY KEY, v TEXT);
    """)
    db.commit()
    return db


def budget_db():
    # Same schema budgetbot created; executescript is a no-op on the live
    # ledger but lets a fresh host bootstrap too.
    db = connect(BUDGET_DB_PATH)
    db.executescript("""
        CREATE TABLE IF NOT EXISTS tx(
            id INTEGER PRIMARY KEY,
            date TEXT NOT NULL,            -- ISO yyyy-mm-dd, local
            payee TEXT NOT NULL,
            amount_cents INTEGER NOT NULL, -- positive = spending
            category TEXT NOT NULL,
            note TEXT DEFAULT '',
            entered_by TEXT NOT NULL,
            event_id TEXT UNIQUE,
            created_ts INTEGER NOT NULL,
            deleted INTEGER NOT NULL DEFAULT 0  -- soft delete: recoverable
        );
        CREATE TABLE IF NOT EXISTS categories(name TEXT PRIMARY KEY);
        CREATE TABLE IF NOT EXISTS processed(event_id TEXT PRIMARY KEY, ts INTEGER);
        CREATE TABLE IF NOT EXISTS meta(k TEXT PRIMARY KEY, v TEXT);
    """)
    if not db.execute("SELECT 1 FROM categories LIMIT 1").fetchone():
        db.executemany("INSERT INTO categories(name) VALUES (?)",
                       [(c,) for c in DEFAULT_CATEGORIES])
    db.commit()
    return db


def meta_get(db, k):
    row = db.execute("SELECT v FROM meta WHERE k=?", (k,)).fetchone()
    return row["v"] if row else None


def meta_set(db, k, v):
    db.execute("INSERT INTO meta(k,v) VALUES(?,?) ON CONFLICT(k) DO UPDATE SET v=excluded.v", (k, v))
    db.commit()


def git_snapshot(db, db_path, reason):
    """Commit a full SQL dump of a database to a git repo next to it.

    Every mutation lands as one commit, so any past state is one
    `git show`/`git checkout` away even if a bug (or a mis-parsed message)
    mangles the live database. Failures are logged, never fatal — history
    is a safety net, not a dependency. For the budget ledger this is the
    SAME history repo budgetbot kept (/var/lib/budgetbot/history).
    """
    try:
        hist = os.path.join(os.path.dirname(db_path), "history")
        os.makedirs(hist, exist_ok=True)
        if not os.path.isdir(os.path.join(hist, ".git")):
            subprocess.run(["git", "init", "-q"], cwd=hist, check=True)
        # budgetbot's history file was ledger.sql; keep appending to it so
        # the ledger's history stays one unbroken series.
        name = "ledger.sql" if db_path == BUDGET_DB_PATH else "home.sql"
        with open(os.path.join(hist, name), "w") as f:
            for line in db.iterdump():
                f.write(line + "\n")
        subprocess.run(["git", "add", name], cwd=hist, check=True)
        subprocess.run(
            ["git", "-c", "user.name=remy", "-c", "user.email=remy@localhost",
             "commit", "-q", "-m", reason, "--allow-empty-message"],
            cwd=hist, check=False)  # nothing-to-commit is fine
    except Exception:
        log.exception("git snapshot failed")


def today():
    return datetime.now(TZ).date()


# ---------------------------------------------------------------- LLM

def llm_call(system, text, schema):
    body = {
        "model": LLM_MODEL,
        "messages": [{"role": "system", "content": system},
                     {"role": "user", "content": text}],
        "response_format": {"type": "json_schema",
                            "json_schema": {"name": "action", "schema": schema}},
        # No thinking for a classification call: reasoning tokens count
        # against max_tokens and can starve the JSON entirely (bit budgetbot
        # live); this also cuts reply latency to ~a second.
        "chat_template_kwargs": {"enable_thinking": False},
        "temperature": 0.1,
        "max_tokens": 800,
    }
    resp = requests.post(LLM_URL, json=body, timeout=180)
    resp.raise_for_status()
    content = resp.json()["choices"][0]["message"]["content"]
    m = re.search(r"\{.*\}", content, re.S)
    return json.loads(m.group(0) if m else content)


# ================================================================ household
# Tasks with due dates + named lists, and the scheduled day posts.

def open_tasks(db):
    return db.execute(
        "SELECT * FROM task WHERE deleted=0 AND done_ts IS NULL "
        "ORDER BY CASE WHEN due='' THEN 1 ELSE 0 END, due, id").fetchall()


def open_items(db):
    return db.execute(
        "SELECT * FROM item WHERE deleted=0 AND done_ts IS NULL "
        "ORDER BY list_name, id").fetchall()


def fmt_due(due):
    if not due:
        return ""
    d = date.fromisoformat(due)
    delta = (d - today()).days
    nice = d.strftime("%a %b %-d")
    if delta < 0:
        return f" (was due {nice})"
    if delta == 0:
        return " (today)"
    if delta == 1:
        return " (tomorrow)"
    return f" (by {nice})"


def fmt_task(r):
    return f"#{r['id']} {r['title']}{fmt_due(r['due'])}"


def calendar_events(day_from, day_to):
    """Events with a start date in [day_from, day_to], from the sync file.

    Returns (events, note): events sorted by start; note is a staleness
    warning string or "". Missing/broken file = no events, no crash — the
    calendar section simply doesn't render.
    """
    try:
        with open(CAL_PATH) as f:
            data = json.load(f)
    except Exception:
        return [], ""
    out = []
    for ev in data.get("events", []):
        try:
            d = date.fromisoformat(ev["start"][:10])
        except Exception:
            continue
        if day_from <= d <= day_to:
            out.append(ev)
    out.sort(key=lambda e: e["start"])
    note = ""
    fetched = data.get("fetched_at", 0)
    if fetched and time.time() - fetched > 24 * 3600:
        note = "(calendar last synced >1 day ago)"
    return out, note


def fmt_event(ev):
    start = ev["start"]
    if len(start) > 10:  # datetime, not all-day
        when = datetime.fromisoformat(start).astimezone(TZ).strftime("%-H:%M")
    else:
        when = "all day"
    who = f" — {ev['calendar']}" if ev.get("calendar") else ""
    return f"{when}  {ev.get('summary', '(untitled)')}{who}"


HOME_SCHEMA = {
    "type": "object",
    "properties": {
        "intent": {"type": "string",
                   "enum": ["task_add", "task_done", "task_edit", "task_snooze",
                            "task_delete", "task_restore", "tasks_show",
                            "item_add", "item_done", "item_remove", "list_show",
                            "list_clear", "post_now", "help", "other"]},
        "title": {"type": "string"},
        "due": {"type": "string"},
        "task_id": {"type": "integer"},
        "new_title": {"type": "string"},
        "new_due": {"type": "string"},
        "scope": {"type": "string",
                  "enum": ["today", "week", "all", "overdue", "done", ""]},
        "list_name": {"type": "string"},
        "items": {"type": "array", "items": {"type": "string"}},
        "item_id": {"type": "integer"},
        "kind": {"type": "string", "enum": ["morning", "evening", "week", ""]},
        "reply": {"type": "string"},
    },
    # Every field required: with a grammar-constrained lazy model, optional
    # fields simply never get emitted (budgetbot live finding). Unused
    # fields carry "" / 0 / [].
    "required": ["intent", "title", "due", "task_id", "new_title", "new_due",
                 "scope", "list_name", "items", "item_id", "kind", "reply"],
}


def home_parse(db, sender_name, text):
    now = today()
    tasks = "\n".join(fmt_task(r) for r in open_tasks(db)) or "(none)"
    deleted = "\n".join(fmt_task(r) for r in db.execute(
        "SELECT * FROM task WHERE deleted=1 ORDER BY id DESC LIMIT 5"))
    items = "\n".join(f"#{r['id']} [{r['list_name']}] {r['name']}"
                      for r in open_items(db)) or "(none)"
    system = f"""You classify one message from a family household-organizer chat into a JSON action.
Today is {now.isoformat()} ({now.strftime('%A')}). Message author: {sender_name}.
Open tasks (id title due):
{tasks}
Recently deleted tasks (restorable):
{deleted or "(none)"}
Open list items (id [list] name):
{items}

Rules:
- Something the family needs to do ("we need to X by Friday", "X by today/EOD",
  "Thursday we need to X", "remind us to X") => intent task_add. title short,
  imperative, no dates in it; due as ISO yyyy-mm-dd (resolve today/tomorrow/EOD
  = today/weekday names = the NEXT such day, today if it is that day; "" if no
  date was given).
- Marking one finished ("done 3", "did the plumber thing") => task_done with
  task_id from the open list above.
- Moving a date ("push #3 to friday", "snooze the car thing to next week")
  => task_snooze with task_id + new_due. Rewording/changing => task_edit with
  task_id and only the changed new_title/new_due.
- Removing a task => task_delete + task_id; bringing one back => task_restore.
- Adding to a list ("add milk and eggs to shopping", "put batteries on the
  hardware list") => item_add with list_name (short, lowercase; default
  "shopping" for groceries-like things) and items = each thing separately.
- Checking a list item off ("got the milk") => item_done with item_id from the
  list above. Removing one by mistake-entry => item_remove + item_id.
- Showing things: "what's on for today/this week", "show tasks" => tasks_show
  with scope (today|week|all|overdue|done). "show shopping list" / "what
  lists do we have" => list_show with list_name ("" = all lists).
- Emptying a list ("clear the shopping list") => list_clear + list_name.
- Asking for the morning/evening/week summary right now => post_now with kind.
- Asking what you can do => help.
- Anything else (greetings, chatter between the humans, unclear) => intent
  other with reply as a one-line response ONLY if the message was addressed
  to the bot, else reply "".
Every JSON field is required: set unused string fields to "", unused numbers
to 0, unused arrays to []. For task_add, title MUST be filled in.
Output only the JSON object."""
    return llm_call(system, text, HOME_SCHEMA)


def valid_date(s):
    try:
        date.fromisoformat(s)
        return s
    except (ValueError, TypeError):
        return ""


def do_task_add(db, act, sender):
    title = (act.get("title") or "").strip()[:120]
    if not title:
        return "I couldn't make out what the task is — try 'we need to X by friday'."
    due = valid_date(act.get("due", ""))
    db.execute("INSERT INTO task(title,due,created_by,created_ts) VALUES(?,?,?,?)",
               (title, due, sender, int(time.time())))
    db.commit()
    r = db.execute("SELECT * FROM task ORDER BY id DESC LIMIT 1").fetchone()
    return f"✓ added {fmt_task(r)}"


def get_task(db, act, deleted):
    return db.execute("SELECT * FROM task WHERE id=? AND deleted=?",
                      (act.get("task_id"), deleted)).fetchone()


def do_task_done(db, act, sender):
    r = get_task(db, act, 0)
    if not r:
        return "Couldn't tell which task you meant — say it with the #id (e.g. 'done 3')."
    db.execute("UPDATE task SET done_ts=?, done_by=? WHERE id=?",
               (int(time.time()), sender, r["id"]))
    db.commit()
    return f"✔ nice — {r['title']} done"


def do_task_edit(db, act):
    r = get_task(db, act, 0)
    if not r:
        return "Couldn't tell which task you meant — use its #id."
    changes, params = [], []
    if act.get("new_title"):
        changes.append("title=?"); params.append(act["new_title"].strip()[:120])
    if act.get("new_due"):
        changes.append("due=?"); params.append(valid_date(act["new_due"]))
    if not changes:
        return "Nothing to change that I understood."
    db.execute(f"UPDATE task SET {','.join(changes)} WHERE id=?", (*params, r["id"]))
    db.commit()
    return "✏️ " + fmt_task(db.execute("SELECT * FROM task WHERE id=?", (r["id"],)).fetchone())


def do_task_snooze(db, act):
    r = get_task(db, act, 0)
    if not r:
        return "Couldn't tell which task to move — use its #id."
    due = valid_date(act.get("new_due", ""))
    if not due:
        return "Move it to when? ('push #3 to friday')"
    db.execute("UPDATE task SET due=?, done_ts=NULL WHERE id=?", (due, r["id"]))
    db.commit()
    return "⏰ " + fmt_task(db.execute("SELECT * FROM task WHERE id=?", (r["id"],)).fetchone())


def do_task_delete(db, act):
    r = get_task(db, act, 0)
    if not r:
        return "Couldn't tell which task to remove — use its #id."
    db.execute("UPDATE task SET deleted=1 WHERE id=?", (r["id"],))
    db.commit()
    return f"🗑 removed {fmt_task(r)} (say 'restore #{r['id']}' to undo)"


def do_task_restore(db, act):
    r = get_task(db, act, 1)
    if not r:
        return "Nothing deleted under that #id."
    db.execute("UPDATE task SET deleted=0 WHERE id=?", (r["id"],))
    db.commit()
    return "↩️ restored " + fmt_task(r)


def do_tasks_show(db, act):
    scope = act.get("scope") or "all"
    now = today()
    if scope == "done":
        rows = db.execute(
            "SELECT * FROM task WHERE deleted=0 AND done_ts IS NOT NULL "
            "ORDER BY done_ts DESC LIMIT 10").fetchall()
        return "Recently done:\n" + ("\n".join(
            f"✔ #{r['id']} {r['title']} ({r['done_by']})" for r in rows) or "(nothing yet)")
    rows = open_tasks(db)
    if scope == "today":
        rows = [r for r in rows if r["due"] and r["due"] <= now.isoformat()]
        head = "Today (and overdue):"
    elif scope == "overdue":
        rows = [r for r in rows if r["due"] and r["due"] < now.isoformat()]
        head = "Overdue:"
    elif scope == "week":
        end = (now + timedelta(days=7)).isoformat()
        rows = [r for r in rows if r["due"] and r["due"] <= end]
        head = "This week:"
    else:
        head = "Open tasks:"
    return head + "\n" + ("\n".join("• " + fmt_task(r) for r in rows) or "(nothing!)")


def do_item_add(db, act, sender):
    names = [n.strip()[:80] for n in act.get("items", []) if n.strip()]
    if not names:
        return "Add what? ('add milk and eggs to shopping')"
    ln = (act.get("list_name") or "shopping").strip().lower()[:30]
    now_ts = int(time.time())
    for n in names:
        db.execute("INSERT INTO item(list_name,name,added_by,added_ts) VALUES(?,?,?,?)",
                   (ln, n, sender, now_ts))
    db.commit()
    n_open = db.execute("SELECT COUNT(*) c FROM item WHERE list_name=? AND deleted=0 "
                        "AND done_ts IS NULL", (ln,)).fetchone()["c"]
    return f"✓ {', '.join(names)} → {ln} ({n_open} on the list)"


def do_item_done(db, act):
    r = db.execute("SELECT * FROM item WHERE id=? AND deleted=0",
                   (act.get("item_id"),)).fetchone()
    if not r:
        return "Couldn't tell which item — use its #id."
    db.execute("UPDATE item SET done_ts=? WHERE id=?", (int(time.time()), r["id"]))
    db.commit()
    return f"✔ {r['name']} checked off {r['list_name']}"


def do_item_remove(db, act):
    r = db.execute("SELECT * FROM item WHERE id=? AND deleted=0",
                   (act.get("item_id"),)).fetchone()
    if not r:
        return "Couldn't tell which item — use its #id."
    db.execute("UPDATE item SET deleted=1 WHERE id=?", (r["id"],))
    db.commit()
    return f"🗑 {r['name']} off {r['list_name']}"


def do_list_show(db, act):
    ln = (act.get("list_name") or "").strip().lower()
    rows = open_items(db)
    if ln:
        rows = [r for r in rows if r["list_name"] == ln]
        if not rows:
            return f"'{ln}' is empty."
    if not rows:
        return "All lists are empty."
    lines, last = [], None
    for r in rows:
        if r["list_name"] != last:
            lines.append(f"{r['list_name']}:")
            last = r["list_name"]
        lines.append(f"  • #{r['id']} {r['name']}")
    return "\n".join(lines)


def do_list_clear(db, act):
    ln = (act.get("list_name") or "").strip().lower()
    if not ln:
        return "Clear which list?"
    n = db.execute("UPDATE item SET deleted=1 WHERE list_name=? AND deleted=0",
                   (ln,)).rowcount
    db.commit()
    return f"🧹 cleared {ln} ({n} items; restorable from history)"


def week_section(db, start):
    """Tasks due and calendar events for the 7 days from `start`, by day."""
    end = start + timedelta(days=6)
    tasks = [r for r in open_tasks(db)
             if r["due"] and start.isoformat() <= r["due"] <= end.isoformat()]
    events, _ = calendar_events(start, end)
    if not tasks and not events:
        return "📅 Week ahead: clear so far."
    by_day = {}
    for r in tasks:
        by_day.setdefault(r["due"], []).append(f"• #{r['id']} {r['title']}")
    for ev in events:
        by_day.setdefault(ev["start"][:10], []).append("◦ " + fmt_event(ev))
    lines = ["📅 Week ahead:"]
    for d in sorted(by_day):
        lines.append(date.fromisoformat(d).strftime("%A %b %-d") + ":")
        lines += ["  " + s for s in by_day[d]]
    return "\n".join(lines)


def morning_post(db):
    now = today()
    lines = [f"☀️ {now.strftime('%A, %B %-d')}"]
    overdue = [r for r in open_tasks(db) if r["due"] and r["due"] < now.isoformat()]
    due_today = [r for r in open_tasks(db) if r["due"] == now.isoformat()]
    if overdue:
        lines.append("Overdue:")
        lines += [f"  • #{r['id']} {r['title']}{fmt_due(r['due'])}" for r in overdue]
    if due_today:
        lines.append("Today:")
        lines += [f"  • #{r['id']} {r['title']}" for r in due_today]
    events, note = calendar_events(now, now)
    if events:
        lines.append("Calendar:")
        lines += ["  ◦ " + fmt_event(ev) for ev in events]
    if note:
        lines.append(note)
    if len(lines) == 1:
        lines.append("Nothing scheduled — enjoy the day.")
    if now.weekday() == 0:  # Monday: look at the week
        lines.append("")
        lines.append(week_section(db, now))
    return "\n".join(lines)


def evening_post(db):
    now = today()
    day_start = int(datetime.combine(now, datetime.min.time(), TZ).timestamp())
    lines = [f"🌙 Evening report — {now.strftime('%A')}"]
    done = db.execute(
        "SELECT * FROM task WHERE deleted=0 AND done_ts>=? ORDER BY done_ts",
        (day_start,)).fetchall()
    checked = db.execute(
        "SELECT COUNT(*) c FROM item WHERE deleted=0 AND done_ts>=?",
        (day_start,)).fetchone()["c"]
    if done or checked:
        lines.append("Done today:")
        lines += [f"  ✔ {r['title']} ({r['done_by']})" for r in done]
        if checked:
            lines.append(f"  ✔ {checked} list item{'s' if checked > 1 else ''} checked off")
    missed = [r for r in open_tasks(db) if r["due"] and r["due"] <= now.isoformat()]
    if missed:
        lines.append("Didn't get done (carrying over):")
        lines += [f"  • #{r['id']} {r['title']}{fmt_due(r['due'])}" for r in missed]
    tomorrow = now + timedelta(days=1)
    due_tmrw = [r for r in open_tasks(db) if r["due"] == tomorrow.isoformat()]
    events, _ = calendar_events(tomorrow, tomorrow)
    if due_tmrw or events:
        lines.append("Tomorrow:")
        lines += [f"  • #{r['id']} {r['title']}" for r in due_tmrw]
        lines += ["  ◦ " + fmt_event(ev) for ev in events]
    if len(lines) == 1:
        lines.append("Quiet day — nothing logged, nothing due.")
    if now.weekday() == 6:  # Sunday: look at the week
        lines.append("")
        lines.append(week_section(db, tomorrow))
    return "\n".join(lines)


HOME_HELP = """I keep the family's tasks, lists, and day plans. Examples:
• we need to renew the car registration by friday
• thursday we need to take the cat to the vet / done 3 / push #3 to monday
• add milk and eggs to shopping / got the milk / show shopping list
• what's on today? / this week? / show tasks
• morning/evening summary — ask any time; I post them at 7:00 and 19:00
I also show the family calendar in those posts (synced from Migadu).
(Money things live in the Budget room — I answer there too.)"""


# ================================================================ budget
# budgetbot's skill set, verbatim behavior, same ledger.

def fmt_amount(cents):
    return f"${cents / 100:,.2f}"


def fmt_tx(r):
    return f"#{r['id']} {r['date']} {r['payee']} {fmt_amount(r['amount_cents'])} → {r['category']}"


def categories(db):
    return [r["name"] for r in db.execute("SELECT name FROM categories ORDER BY name")]


def recent_tx(db, n=15):
    return db.execute("SELECT * FROM tx WHERE deleted=0 ORDER BY id DESC LIMIT ?",
                      (n,)).fetchall()


BUDGET_SCHEMA = {
    "type": "object",
    "properties": {
        "intent": {"type": "string",
                   "enum": ["add", "edit", "delete", "restore", "query", "chart",
                            "add_category", "help", "other"]},
        "payee": {"type": "string"},
        "amount": {"type": "number"},
        "category": {"type": "string"},
        "date": {"type": "string"},
        "note": {"type": "string"},
        "tx_id": {"type": "integer"},
        "new_amount": {"type": "number"},
        "new_category": {"type": "string"},
        "new_payee": {"type": "string"},
        "query_kind": {"type": "string",
                       "enum": ["month_summary", "category_total", "recent", "compare_months"]},
        "month": {"type": "string"},
        "chart_kind": {"type": "string", "enum": ["month_bar", "trend"]},
        "reply": {"type": "string"},
    },
    "required": ["intent", "payee", "amount", "category", "date", "note",
                 "tx_id", "new_amount", "new_category", "new_payee",
                 "query_kind", "month", "chart_kind", "reply"],
}


def budget_parse(db, sender_name, text):
    now = today()
    recent = "\n".join(fmt_tx(r) for r in recent_tx(db)) or "(none)"
    deleted = "\n".join(fmt_tx(r) for r in db.execute(
        "SELECT * FROM tx WHERE deleted=1 ORDER BY id DESC LIMIT 5"))
    system = f"""You classify one message from a family budget chat into a JSON action.
Today is {now.isoformat()} ({now.strftime('%A')}). Message author: {sender_name}.
Known categories: {", ".join(categories(db))}.
Recent transactions (id date payee amount category):
{recent}
Recently deleted (restorable):
{deleted or "(none)"}

Rules:
- A purchase mention ("costco 84.12", "40 on gas yesterday") => intent add.
  amount in dollars; date ISO (resolve words like yesterday/tuesday, default today);
  payee short and capitalized; pick the closest existing category ("other" if none fits).
- Correcting/changing an existing entry => intent edit, with tx_id from the list
  above and only the new_* fields being changed. Deleting one => intent delete + tx_id.
  Undeleting/bringing one back ("restore #12") => intent restore + tx_id.
- Questions about spending => intent query (pick query_kind; month as yyyy-mm,
  default current month; category_total also needs category).
- Asking for a chart/graph => intent chart (month_bar = this month's categories,
  trend = monthly totals over time).
- "add category X" => intent add_category with category.
- Asking what you can do => intent help.
- Anything else (greetings, chatter between the humans, unclear) => intent other
  with reply as a one-line response ONLY if the message was addressed to the bot,
  else reply "".
Every JSON field is required: set unused string fields to "" and unused
number fields to 0. For intent add, payee, amount, category and date MUST
be filled in.
Output only the JSON object."""
    return llm_call(system, text, BUDGET_SCHEMA)


def do_budget_add(db, act, sender, event_id):
    cents = round(float(act["amount"]) * 100)
    cat = act.get("category") or "other"
    if cat not in categories(db):
        cat = "other"
    day = act.get("date") or today().isoformat()
    payee = (act.get("payee") or "?").strip()[:80]
    db.execute(
        "INSERT INTO tx(date,payee,amount_cents,category,note,entered_by,event_id,created_ts)"
        " VALUES(?,?,?,?,?,?,?,?)",
        (day, payee, cents, cat, act.get("note", "")[:200], sender, event_id, int(time.time())))
    db.commit()
    r = db.execute("SELECT * FROM tx WHERE event_id=?", (event_id,)).fetchone()
    month_total = db.execute(
        "SELECT COALESCE(SUM(amount_cents),0) t FROM tx WHERE date LIKE ? AND deleted=0",
        (day[:7] + "%",)).fetchone()["t"]
    return (f"✓ {fmt_amount(cents)} {payee} → {cat}"
            f"{'' if day == today().isoformat() else ' on ' + day}"
            f"  (#{r['id']}; {day[:7]} total {fmt_amount(month_total)})")


def do_budget_edit(db, act):
    r = db.execute("SELECT * FROM tx WHERE id=?", (act.get("tx_id"),)).fetchone()
    if not r:
        return "Couldn't tell which entry you meant — say it with the #id (e.g. 'change #12 to 84')."
    changes, params = [], []
    if act.get("new_amount"):  # 0 = "not changed" by schema convention
        changes.append("amount_cents=?"); params.append(round(float(act["new_amount"]) * 100))
    if act.get("new_category"):
        cat = act["new_category"] if act["new_category"] in categories(db) else None
        if cat:
            changes.append("category=?"); params.append(cat)
    if act.get("new_payee"):
        changes.append("payee=?"); params.append(act["new_payee"].strip()[:80])
    if act.get("date"):
        changes.append("date=?"); params.append(act["date"])
    if not changes:
        return "Nothing to change that I understood."
    db.execute(f"UPDATE tx SET {','.join(changes)} WHERE id=?", (*params, r["id"]))
    db.commit()
    return "✏️ " + fmt_tx(db.execute("SELECT * FROM tx WHERE id=?", (r["id"],)).fetchone())


def do_budget_delete(db, act):
    r = db.execute("SELECT * FROM tx WHERE id=? AND deleted=0",
                   (act.get("tx_id"),)).fetchone()
    if not r:
        return "Couldn't tell which entry to delete — use its #id."
    db.execute("UPDATE tx SET deleted=1 WHERE id=?", (r["id"],))
    db.commit()
    return f"🗑 removed {fmt_tx(r)} (say 'restore #{r['id']}' to undo)"


def do_budget_restore(db, act):
    r = db.execute("SELECT * FROM tx WHERE id=? AND deleted=1",
                   (act.get("tx_id"),)).fetchone()
    if not r:
        return "Nothing deleted under that #id."
    db.execute("UPDATE tx SET deleted=0 WHERE id=?", (r["id"],))
    db.commit()
    return "↩️ restored " + fmt_tx(r)


def month_rows(db, month):
    return db.execute(
        "SELECT category, SUM(amount_cents) c FROM tx WHERE date LIKE ? AND deleted=0 "
        "GROUP BY category ORDER BY c DESC", (month + "%",)).fetchall()


def do_budget_query(db, act):
    kind = act.get("query_kind", "month_summary")
    month = act.get("month") or today().isoformat()[:7]
    if kind == "recent":
        rows = recent_tx(db, 10)
        return "Recent:\n" + ("\n".join(fmt_tx(r) for r in rows) or "(nothing yet)")
    if kind == "category_total":
        cat = act.get("category") or "other"
        row = db.execute(
            "SELECT COALESCE(SUM(amount_cents),0) c, COUNT(*) n FROM tx "
            "WHERE date LIKE ? AND category=? AND deleted=0", (month + "%", cat)).fetchone()
        return f"{month} {cat}: {fmt_amount(row['c'])} across {row['n']} entries"
    if kind == "compare_months":
        rows = db.execute(
            "SELECT substr(date,1,7) m, SUM(amount_cents) c FROM tx WHERE deleted=0 "
            "GROUP BY m ORDER BY m DESC LIMIT 6").fetchall()
        return "Monthly totals:\n" + "\n".join(f"{r['m']}: {fmt_amount(r['c'])}" for r in rows)
    rows = month_rows(db, month)
    if not rows:
        return f"No entries for {month} yet."
    total = sum(r["c"] for r in rows)
    lines = [f"{month} — total {fmt_amount(total)}"]
    lines += [f"  {r['category']}: {fmt_amount(r['c'])}" for r in rows]
    return "\n".join(lines)


def make_chart(db, act):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    fig, ax = plt.subplots(figsize=(7, 4), dpi=140)
    if act.get("chart_kind") == "trend":
        rows = db.execute(
            "SELECT substr(date,1,7) m, SUM(amount_cents)/100.0 t FROM tx "
            "WHERE deleted=0 GROUP BY m ORDER BY m").fetchall()
        ax.plot([r["m"] for r in rows], [r["t"] for r in rows], marker="o")
        ax.set_title("Monthly spending")
        title = "trend.png"
    else:
        month = act.get("month") or today().isoformat()[:7]
        rows = month_rows(db, month)
        ax.bar([r["category"] for r in rows], [r["c"] / 100 for r in rows])
        ax.set_title(f"Spending by category — {month}")
        ax.tick_params(axis="x", rotation=30)
        title = f"{month}.png"
    ax.set_ylabel("$")
    fig.tight_layout()
    buf = io.BytesIO()
    fig.savefig(buf, format="png")
    plt.close(fig)
    buf.seek(0)
    return title, buf


BUDGET_HELP = """I file whatever you type into the ledger. Examples:
• costco 84.12 — logs a purchase (I guess the category)
• gas 40 yesterday / lunch 15 last tuesday
• change #12 to 84 / #12 was household / delete #12 / restore #12
• how much on groceries this month? / recent / monthly totals
• chart / trend — pictures
• add category kids"""


# ================================================================ bot

class Bot:
    def __init__(self):
        self.hdb = home_db()
        self.bdb = budget_db()
        self.client = AsyncClient(HS_URL, USER_ID)
        self.home_room = None

    async def send(self, room_id, text, notify=False):
        # Scheduled posts are m.text (they should ping phones); command
        # replies are m.notice (quieter, and other bots ignore notices).
        await self.client.room_send(room_id, "m.room.message", {
            "msgtype": "m.text" if notify else "m.notice", "body": text})

    async def send_image(self, room_id, name, buf):
        data = buf.getvalue()
        resp, _ = await self.client.upload(io.BytesIO(data), content_type="image/png",
                                           filename=name, filesize=len(data))
        if not getattr(resp, "content_uri", None):
            await self.send(room_id, "(chart upload failed)")
            return
        await self.client.room_send(room_id, "m.room.message", {
            "msgtype": "m.image", "body": name, "url": resp.content_uri,
            "info": {"mimetype": "image/png", "size": len(data)},
        })

    # -------------------------------------------------------- dispatch

    async def on_message(self, room, event):
        if event.sender == self.client.user_id:
            return
        if room.room_id == self.home_room:
            handler = self.handle_home
        elif room.room_id == BUDGET_ROOM_ID:
            handler = self.handle_budget
        else:
            return
        # One processed-table (the household db) covers both rooms.
        if self.hdb.execute("SELECT 1 FROM processed WHERE event_id=?",
                            (event.event_id,)).fetchone():
            return
        self.hdb.execute("INSERT INTO processed(event_id,ts) VALUES(?,?)",
                         (event.event_id, int(time.time())))
        self.hdb.commit()
        # Replay policy: catch up on messages missed while down (up to 7
        # days), but NEVER before this database first existed — a fresh DB
        # must not chew either room's prior history into duplicate entries
        # (the Budget room has weeks of already-filed messages).
        first_start = int(meta_get(self.hdb, "first_start_ms") or 0)
        if event.server_timestamp < max(first_start, START_MS - 7 * 86400 * 1000):
            return
        text = event.body.strip()
        if not text:
            return
        sender = event.sender.split(":")[0].lstrip("@")
        try:
            await handler(room.room_id, sender, event, text)
        except Exception:
            log.exception("action failed")
            await self.send(room.room_id, "(something broke doing that — it's logged)")

    async def handle_home(self, room_id, sender, event, text):
        try:
            act = await asyncio.to_thread(home_parse, self.hdb, sender, text)
        except Exception:
            log.exception("parse failed")
            await self.send(room_id, "(I choked parsing that — try again?)")
            return
        log.info("home %s: %r -> %s", sender, text, act.get("intent"))
        intent = act.get("intent")
        mutated = intent in ("task_add", "task_done", "task_edit", "task_snooze",
                             "task_delete", "task_restore", "item_add",
                             "item_done", "item_remove", "list_clear")
        handlers = {
            "task_add": lambda: do_task_add(self.hdb, act, sender),
            "task_done": lambda: do_task_done(self.hdb, act, sender),
            "task_edit": lambda: do_task_edit(self.hdb, act),
            "task_snooze": lambda: do_task_snooze(self.hdb, act),
            "task_delete": lambda: do_task_delete(self.hdb, act),
            "task_restore": lambda: do_task_restore(self.hdb, act),
            "tasks_show": lambda: do_tasks_show(self.hdb, act),
            "item_add": lambda: do_item_add(self.hdb, act, sender),
            "item_done": lambda: do_item_done(self.hdb, act),
            "item_remove": lambda: do_item_remove(self.hdb, act),
            "list_show": lambda: do_list_show(self.hdb, act),
            "list_clear": lambda: do_list_clear(self.hdb, act),
        }
        if intent in handlers:
            await self.send(room_id, handlers[intent]())
        elif intent == "post_now":
            kind = act.get("kind") or "morning"
            make = {"week": lambda db: week_section(db, today()),
                    "evening": evening_post}.get(kind, morning_post)
            await self.send(room_id, make(self.hdb))
        elif intent == "help":
            await self.send(room_id, HOME_HELP)
        elif intent == "other" and act.get("reply"):
            await self.send(room_id, act["reply"][:400])
        if mutated:
            await asyncio.to_thread(git_snapshot, self.hdb, DB_PATH,
                                    f"{intent} by {sender}: {text[:60]}")

    async def handle_budget(self, room_id, sender, event, text):
        try:
            act = await asyncio.to_thread(budget_parse, self.bdb, sender, text)
        except Exception:
            log.exception("parse failed")
            await self.send(room_id, "(I choked parsing that — try again?)")
            return
        log.info("budget %s: %r -> %s", sender, text, act.get("intent"))
        intent = act.get("intent")
        mutated = intent in ("add", "edit", "delete", "restore", "add_category")
        if intent == "add" and act.get("amount"):
            await self.send(room_id, do_budget_add(self.bdb, act, sender, event.event_id))
        elif intent == "edit":
            await self.send(room_id, do_budget_edit(self.bdb, act))
        elif intent == "delete":
            await self.send(room_id, do_budget_delete(self.bdb, act))
        elif intent == "restore":
            await self.send(room_id, do_budget_restore(self.bdb, act))
        elif intent == "query":
            await self.send(room_id, do_budget_query(self.bdb, act))
        elif intent == "chart":
            name, buf = await asyncio.to_thread(make_chart, self.bdb, act)
            await self.send_image(room_id, name, buf)
        elif intent == "add_category":
            cat = (act.get("category") or "").strip().lower()[:30]
            if cat:
                self.bdb.execute(
                    "INSERT OR IGNORE INTO categories(name) VALUES(?)", (cat,))
                self.bdb.commit()
                await self.send(room_id, f"category '{cat}' added")
        elif intent == "help":
            await self.send(room_id, BUDGET_HELP)
        elif intent == "other" and act.get("reply"):
            await self.send(room_id, act["reply"][:400])
        if mutated:
            await asyncio.to_thread(git_snapshot, self.bdb, BUDGET_DB_PATH,
                                    f"{intent} by {sender}: {text[:60]}")

    # -------------------------------------------------------- schedules

    async def scheduler(self):
        """All timed posts, one minute-tick loop.

        Each post is stamped per-day in meta, so a restart after its time
        still posts (late) exactly once, and a downed bot never back-fills
        yesterday's posts.
        """
        while True:
            await asyncio.sleep(60)
            now = datetime.now(TZ)
            hhmm = now.strftime("%H:%M")
            day = now.date().isoformat()
            # Household: morning plan + evening report.
            for key, at, make in (("morning", MORNING, morning_post),
                                  ("evening", EVENING, evening_post)):
                if hhmm >= at and meta_get(self.hdb, f"last_{key}") != day:
                    meta_set(self.hdb, f"last_{key}", day)
                    try:
                        await self.send(self.home_room, make(self.hdb), notify=True)
                    except Exception:
                        log.exception("%s post failed", key)
            # Budget: Sunday check-in / stale-entry nag (budgetbot behavior,
            # including its meta key — the last stamp carries over).
            if now.hour == BUDGET_REMIND_HOUR and BUDGET_ROOM_ID \
                    and meta_get(self.bdb, "last_reminder") != day:
                last = self.bdb.execute("SELECT MAX(date) d FROM tx").fetchone()["d"]
                stale = (not last or
                         (now.date() - date.fromisoformat(last)).days >= BUDGET_STALE_DAYS)
                try:
                    if now.weekday() == 6:
                        meta_set(self.bdb, "last_reminder", day)
                        await self.send(BUDGET_ROOM_ID,
                                        "Sunday check-in.\n" + do_budget_query(self.bdb, {}))
                    elif stale:
                        meta_set(self.bdb, "last_reminder", day)
                        days = "ever" if not last else f"since {last}"
                        await self.send(BUDGET_ROOM_ID,
                                        f"No entries {days} — anything to log?")
                except Exception:
                    log.exception("budget reminder failed")

    # -------------------------------------------------------- lifecycle

    async def on_invite(self, room, event):
        # The adopt oneshot (the old budgetbot account) invites us to the
        # Budget room; accept only rooms we expect.
        if room.room_id == BUDGET_ROOM_ID:
            await self.client.join(room.room_id)
            log.info("joined budget room %s", room.room_id)

    async def ensure_rooms(self):
        """First start: create the Household room; join Budget if invited."""
        self.home_room = meta_get(self.hdb, "room_id")
        if not self.home_room:
            resp = await self.client.room_create(
                name=ROOM_NAME,
                topic="Tasks, lists, and the day's plan — talk to me in plain language.",
                invite=INVITE_USERS,
                # The first invitee (the captain) gets admin alongside the bot.
                power_level_override={
                    "users": {self.client.user_id: 100,
                              **({INVITE_USERS[0]: 100} if INVITE_USERS else {})}},
            )
            if not getattr(resp, "room_id", None):
                raise SystemExit(f"room create failed: {resp}")
            self.home_room = resp.room_id
            meta_set(self.hdb, "room_id", self.home_room)
            log.info("created room %s (%s)", ROOM_NAME, self.home_room)
        if BUDGET_ROOM_ID:
            # Idempotent; succeeds once the adopt oneshot has invited us,
            # no-ops on every later start, fails harmlessly before then.
            resp = await self.client.join(BUDGET_ROOM_ID)
            if not getattr(resp, "room_id", None):
                log.warning("not in budget room yet (%s)", resp)

    async def run(self):
        if not meta_get(self.hdb, "first_start_ms"):
            meta_set(self.hdb, "first_start_ms", str(START_MS))
        # Reuse a stored device/token when valid; else password login.
        tok, dev = meta_get(self.hdb, "access_token"), meta_get(self.hdb, "device_id")
        if tok and dev:
            self.client.restore_login(USER_ID, dev, tok)
            whoami = await self.client.whoami()
            if getattr(whoami, "user_id", None) != USER_ID:
                tok = None
        if not (tok and dev):
            resp = await self.client.login(PASSWORD, device_name="remy")
            if not getattr(resp, "access_token", None):
                raise SystemExit(f"login failed: {resp}")
            meta_set(self.hdb, "access_token", resp.access_token)
            meta_set(self.hdb, "device_id", resp.device_id)
        await self.ensure_rooms()
        self.client.add_event_callback(self.on_message, RoomMessageText)
        self.client.add_event_callback(self.on_invite, InviteMemberEvent)
        log.info("remy up as %s (home %s, budget %s)",
                 USER_ID, self.home_room, BUDGET_ROOM_ID or "-")
        asyncio.get_event_loop().create_task(self.scheduler())
        await self.client.sync_forever(timeout=30000, full_state=True)


if __name__ == "__main__":
    asyncio.run(Bot().run())
