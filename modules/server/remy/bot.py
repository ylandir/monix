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
            assignee TEXT NOT NULL DEFAULT '',  -- '' = whole household
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
        CREATE TABLE IF NOT EXISTS cal_outbox(
            id INTEGER PRIMARY KEY,
            summary TEXT NOT NULL,
            start TEXT NOT NULL,            -- 'yyyy-mm-dd HH:MM' or all-day 'yyyy-mm-dd'
            created_by TEXT NOT NULL,
            created_ts INTEGER NOT NULL,
            pushed_ts INTEGER,              -- NULL = awaiting the sync unit
            error TEXT NOT NULL DEFAULT ''
        );
        CREATE TABLE IF NOT EXISTS reminder(
            id INTEGER PRIMARY KEY,
            text TEXT NOT NULL,
            at TEXT NOT NULL,               -- local 'yyyy-mm-dd HH:MM'
            assignee TEXT NOT NULL DEFAULT '',  -- '' = whole household
            created_by TEXT NOT NULL,
            created_ts INTEGER NOT NULL,
            fired_ts INTEGER,               -- NULL = pending
            deleted INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS processed(event_id TEXT PRIMARY KEY, ts INTEGER);
        CREATE TABLE IF NOT EXISTS meta(k TEXT PRIMARY KEY, v TEXT);
    """)
    # Migration for databases created before assignees existed (2026-07-13).
    if "assignee" not in [r[1] for r in db.execute("PRAGMA table_info(task)")]:
        db.execute("ALTER TABLE task ADD COLUMN assignee TEXT NOT NULL DEFAULT ''")
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

def llm_call(system, text, schema, max_tokens=800):
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
        "max_tokens": max_tokens,
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


# localparts of the invited family accounts — the names the parser may
# assign tasks to.
FAMILY = [u.split(":")[0].lstrip("@") for u in INVITE_USERS]


def fmt_who(r):
    return f" — {r['assignee']}" if r["assignee"] else ""


def fmt_task(r):
    return f"#{r['id']} {r['title']}{fmt_who(r)}{fmt_due(r['due'])}"


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


HOME_ACTION = {
    "type": "object",
    "properties": {
        "intent": {"type": "string",
                   "enum": ["task_add", "task_done", "task_edit", "task_snooze",
                            "task_delete", "task_restore", "tasks_show",
                            "remind_add", "remind_cancel", "remind_show",
                            "cal_add",
                            "item_add", "item_done", "item_remove", "list_show",
                            "list_clear", "post_now", "help", "other"]},
        "title": {"type": "string"},
        "due": {"type": "string"},
        "at": {"type": "string"},
        "rem_id": {"type": "integer"},
        "assignee": {"type": "string"},
        "task_id": {"type": "integer"},
        "new_title": {"type": "string"},
        "new_due": {"type": "string"},
        "new_assignee": {"type": "string"},
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
    "required": ["intent", "title", "due", "at", "rem_id", "assignee",
                 "task_id", "new_title", "new_due", "new_assignee", "scope",
                 "list_name", "items", "item_id", "kind", "reply"],
}

# One message can carry several actions ("by EOD we need X, and by friday
# Y" = two task_adds) — live finding from the captain's very first message.
HOME_SCHEMA = {
    "type": "object",
    "properties": {
        "actions": {"type": "array", "items": HOME_ACTION, "minItems": 1},
    },
    "required": ["actions"],
}


def home_parse(db, sender_name, text):
    now_dt = datetime.now(TZ)
    now = now_dt.date()
    tasks = "\n".join(fmt_task(r) for r in open_tasks(db)) or "(none)"
    deleted = "\n".join(fmt_task(r) for r in db.execute(
        "SELECT * FROM task WHERE deleted=1 ORDER BY id DESC LIMIT 5"))
    items = "\n".join(f"#{r['id']} [{r['list_name']}] {r['name']}"
                      for r in open_items(db)) or "(none)"
    reminders = "\n".join(fmt_reminder(r) for r in pending_reminders(db)) or "(none)"
    system = f"""You classify one message from a family household-organizer chat into a JSON list of actions.
A message may contain SEVERAL actions ("by today we need X, and by friday Y"
= two task_adds; "add milk, and remind us to call the vet thursday" =
item_add + task_add) — emit one action object per thing, in message order.
Most messages are exactly one action.
Today is {now.isoformat()} ({now.strftime('%A')}) and the time right now is
{now_dt.strftime('%H:%M')} (24h) — resolve relative times ("in 5 minutes",
"in an hour") from that. Message author: {sender_name}.
Open tasks (id title due):
{tasks}
Recently deleted tasks (restorable):
{deleted or "(none)"}
Open list items (id [list] name):
{items}
Pending reminders (id time text):
{reminders}

Rules:
- Something the family needs to do ("we need to X by Friday", "X by today/EOD",
  "Thursday we need to X", "remind us to X") => intent task_add. title short,
  imperative, no dates or names in it; due as ISO yyyy-mm-dd (resolve
  today/tomorrow/EOD = today/weekday names = the NEXT such day, today if it is
  that day; "" if no date was given). assignee: if the task is for one
  specific person ("I need dylan to X", "gab should X", "remind me to X" =
  the author) use their name from [{", ".join(FAMILY)}], else "" (whole
  household).
- Marking one finished ("done 3", "did the plumber thing") => task_done with
  task_id from the open list above.
- Moving a date ("push #3 to friday", "snooze the car thing to next week")
  => task_snooze with task_id + new_due. Rewording/changing/reassigning
  ("give #3 to gab") => task_edit with task_id and only the changed
  new_title/new_due/new_assignee.
- Removing a task => task_delete + task_id; bringing one back => task_restore.
- Wanting a PING at a specific moment ("remind me at 5 to leave", "remind us
  thursday at 9am to put the bins out", "tomorrow morning remind me to X")
  => remind_add with title (the thing, short) and at as 'yyyy-mm-dd HH:MM'
  24h local (resolve like due dates; morning=09:00, noon=12:00,
  afternoon=15:00, evening/tonight=19:00; bare "at 5" after noon means
  17:00). assignee as for tasks ("remind me" = the author, "remind us" = "").
  A DAY deadline with no clock time ("by friday") stays a task_add, NOT a
  reminder. Cancelling one => remind_cancel with rem_id from the pending
  list above; "what reminders are set" => remind_show.
- An APPOINTMENT/EVENT to go on the family calendar ("put the dentist on
  the calendar tuesday at 3", "add gab's recital to the calendar friday",
  "we have dinner with the smiths saturday 7pm") => cal_add with title and
  at ('yyyy-mm-dd HH:MM', or just 'yyyy-mm-dd' for an all-day event).
  Calendar = something happening; task = something to do; reminder = a ping.
- Adding to a list ("add milk and eggs to shopping", "put batteries on the
  hardware list") => item_add with list_name (short, lowercase; default
  "shopping" for groceries-like things) and items = each thing separately.
- Checking a list item off ("got the milk") => item_done with item_id from the
  list above. Removing one by mistake-entry => item_remove + item_id.
- Starting a fresh list with nothing on it yet ("make a grocery list")
  => item_add with that list_name and items [].
- Showing things: "what's on for today/this week", "show tasks" => tasks_show
  with scope (today|week|all|overdue|done); if they ask about ONE person's
  tasks ("what's on dylan's plate") also set assignee. "show shopping list" /
  "what lists do we have" => list_show with list_name ("" = all lists).
- Emptying a list ("clear the shopping list") => list_clear + list_name.
- Asking for the morning/evening/week summary right now => post_now with kind.
- Asking what you can do => help.
- Anything else (greetings, chatter between the humans, unclear) => intent
  other with reply as a one-line response ONLY if the message was addressed
  to the bot, else reply "".
Every JSON field is required in every action: set unused string fields to "",
unused numbers to 0, unused arrays to []. For task_add, title MUST be filled
in. Chatter not addressed to the bot = one "other" action with reply "".
Output only the JSON object: {{"actions": [...]}}."""
    # Generous token budget: several actions × all-required fields (local
    # tokens are free; a starved response is not).
    return llm_call(system, text, HOME_SCHEMA, max_tokens=2000).get("actions", [])


def valid_date(s):
    try:
        date.fromisoformat(s)
        return s
    except (ValueError, TypeError):
        return ""


def valid_assignee(s):
    s = (s or "").strip().lower()
    return s if s in FAMILY else ""


# ---------------------------------------------------------------- reminders

def pending_reminders(db):
    return db.execute(
        "SELECT * FROM reminder WHERE deleted=0 AND fired_ts IS NULL "
        "ORDER BY at").fetchall()


def fmt_reminder(r):
    d = date.fromisoformat(r["at"][:10])
    day = ("today" if d == today() else "tomorrow" if d == today() + timedelta(days=1)
           else d.strftime("%a %b %-d"))
    who = f" — {r['assignee']}" if r["assignee"] else ""
    return f"#{r['id']} {day} {r['at'][11:]} {r['text']}{who}"


def valid_at(s):
    """Normalize a 'yyyy-mm-dd HH:MM' (or ISO T) local timestamp, else ''."""
    try:
        return datetime.strptime((s or "").strip().replace("T", " ")[:16],
                                 "%Y-%m-%d %H:%M").strftime("%Y-%m-%d %H:%M")
    except ValueError:
        return ""


def do_remind_add(db, act, sender):
    text = (act.get("title") or "").strip()[:120]
    at = valid_at(act.get("at"))
    if not text or not at:
        return "Remind who to do what, when? ('remind me thursday at 9 to call the vet')"
    if at < datetime.now(TZ).strftime("%Y-%m-%d %H:%M"):
        return f"{at} is already in the past — when should I actually ping?"
    who = valid_assignee(act.get("assignee"))
    db.execute("INSERT INTO reminder(text,at,assignee,created_by,created_ts)"
               " VALUES(?,?,?,?,?)", (text, at, who, sender, int(time.time())))
    db.commit()
    r = db.execute("SELECT * FROM reminder ORDER BY id DESC LIMIT 1").fetchone()
    return f"⏰ will do — {fmt_reminder(r)}"


OUTBOX_FLAG = os.path.join(os.path.dirname(DB_PATH), "outbox.flag")


def do_cal_add(db, act, sender):
    title = (act.get("title") or "").strip()[:120]
    at = valid_at(act.get("at")) or valid_date((act.get("at") or "").strip()[:10])
    if not title or not at:
        return "Put what on the calendar, when? ('dentist on the calendar tuesday at 3')"
    db.execute("INSERT INTO cal_outbox(summary,start,created_by,created_ts)"
               " VALUES(?,?,?,?)", (title, at, sender, int(time.time())))
    db.commit()
    # Poke the credentialed sync unit (a systemd path unit watches this
    # file); the event is on Migadu within seconds.
    try:
        with open(OUTBOX_FLAG, "w") as f:
            f.write(str(time.time()))
    except OSError:
        log.exception("outbox flag write failed")  # 30-min timer still delivers
    d = date.fromisoformat(at[:10])
    when = d.strftime("%a %b %-d") + (f" {at[11:]}" if len(at) > 10 else " (all day)")
    return f"🗓 {title} — {when}, putting it on the calendar now"


def do_remind_cancel(db, act):
    r = db.execute("SELECT * FROM reminder WHERE id=? AND deleted=0 AND fired_ts IS NULL",
                   (act.get("rem_id"),)).fetchone()
    if not r:
        return "Couldn't tell which reminder — use its #id ('cancel reminder 2')."
    db.execute("UPDATE reminder SET deleted=1 WHERE id=?", (r["id"],))
    db.commit()
    return f"🗑 cancelled {fmt_reminder(r)}"


def do_remind_show(db):
    rows = pending_reminders(db)
    return "Reminders set:\n" + ("\n".join("⏰ " + fmt_reminder(r) for r in rows)
                                 or "(none)")


def do_task_add(db, act, sender):
    title = (act.get("title") or "").strip()[:120]
    if not title:
        return "I couldn't make out what the task is — try 'we need to X by friday'."
    due = valid_date(act.get("due", ""))
    who = valid_assignee(act.get("assignee"))
    db.execute("INSERT INTO task(title,due,assignee,created_by,created_ts) VALUES(?,?,?,?,?)",
               (title, due, who, sender, int(time.time())))
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
    if act.get("new_assignee"):
        changes.append("assignee=?"); params.append(valid_assignee(act["new_assignee"]))
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
    who = valid_assignee(act.get("assignee"))
    if who:
        rows = [r for r in rows if r["assignee"] == who]
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
    ln = (act.get("list_name") or "shopping").strip().lower()[:30]
    if not names:
        # "make a grocery list": lists exist once something is on them, so
        # just teach the phrasing.
        return f"👍 '{ln}' it is — put things on it like 'add milk to {ln}'."
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
        by_day.setdefault(r["due"], []).append(f"• #{r['id']} {r['title']}{fmt_who(r)}")
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
        lines += [f"  • #{r['id']} {r['title']}{fmt_who(r)}{fmt_due(r['due'])}" for r in overdue]
    if due_today:
        lines.append("Today:")
        lines += [f"  • #{r['id']} {r['title']}{fmt_who(r)}" for r in due_today]
    rems = [r for r in pending_reminders(db) if r["at"][:10] == now.isoformat()]
    if rems:
        lines.append("Reminders today:")
        lines += [f"  ⏰ {r['at'][11:]} {r['text']}{fmt_who(r)}" for r in rems]
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
        lines += [f"  • #{r['id']} {r['title']}{fmt_who(r)}{fmt_due(r['due'])}" for r in missed]
    tomorrow = now + timedelta(days=1)
    due_tmrw = [r for r in open_tasks(db) if r["due"] == tomorrow.isoformat()]
    events, _ = calendar_events(tomorrow, tomorrow)
    if due_tmrw or events:
        lines.append("Tomorrow:")
        lines += [f"  • #{r['id']} {r['title']}{fmt_who(r)}" for r in due_tmrw]
        lines += ["  ◦ " + fmt_event(ev) for ev in events]
    if len(lines) == 1:
        lines.append("Quiet day — nothing logged, nothing due.")
    if now.weekday() == 6:  # Sunday: look at the week
        lines.append("")
        lines.append(week_section(db, tomorrow))
    return "\n".join(lines)


HOME_HELP = """I keep the family's tasks, lists, and day plans. Examples:
• we need to renew the car registration by friday
• I need dylan to call the plumber by thursday / what's on gab's plate?
• remind me thursday at 9 to defrost the chicken / what reminders are set?
• put the dentist on the calendar tuesday at 3 — goes straight to Migadu
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

    async def send(self, room_id, text, notify=False, mention=None):
        # Scheduled posts are m.text (they should ping phones); command
        # replies are m.notice (quieter, and other bots ignore notices).
        # mention: a FAMILY localpart for a personal ping, or "room" for
        # everyone — MSC4142 m.mentions is what makes phones buzz.
        content = {"msgtype": "m.text" if notify else "m.notice", "body": text}
        if mention == "room":
            content["m.mentions"] = {"room": True}
        elif mention:
            domain = self.client.user_id.split(":", 1)[1]
            content["m.mentions"] = {"user_ids": [f"@{mention}:{domain}"]}
        await self.client.room_send(room_id, "m.room.message", content)

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
            acts = await asyncio.to_thread(home_parse, self.hdb, sender, text)
        except Exception:
            log.exception("parse failed")
            await self.send(room_id, "(I choked parsing that — try again?)")
            return
        log.info("home %s: %r -> %s", sender, text,
                 [a.get("intent") for a in acts])
        MUTATORS = ("task_add", "task_done", "task_edit", "task_snooze",
                    "task_delete", "task_restore", "cal_add", "remind_add",
                    "remind_cancel", "item_add",
                    "item_done", "item_remove", "list_clear")
        replies, mutated = [], []
        for act in acts[:8]:  # runaway-parse backstop
            intent = act.get("intent")
            handlers = {
                "task_add": lambda a=act: do_task_add(self.hdb, a, sender),
                "task_done": lambda a=act: do_task_done(self.hdb, a, sender),
                "task_edit": lambda a=act: do_task_edit(self.hdb, a),
                "task_snooze": lambda a=act: do_task_snooze(self.hdb, a),
                "task_delete": lambda a=act: do_task_delete(self.hdb, a),
                "task_restore": lambda a=act: do_task_restore(self.hdb, a),
                "tasks_show": lambda a=act: do_tasks_show(self.hdb, a),
                "cal_add": lambda a=act: do_cal_add(self.hdb, a, sender),
                "remind_add": lambda a=act: do_remind_add(self.hdb, a, sender),
                "remind_cancel": lambda a=act: do_remind_cancel(self.hdb, a),
                "remind_show": lambda: do_remind_show(self.hdb),
                "item_add": lambda a=act: do_item_add(self.hdb, a, sender),
                "item_done": lambda a=act: do_item_done(self.hdb, a),
                "item_remove": lambda a=act: do_item_remove(self.hdb, a),
                "list_show": lambda a=act: do_list_show(self.hdb, a),
                "list_clear": lambda a=act: do_list_clear(self.hdb, a),
            }
            if intent in handlers:
                replies.append(handlers[intent]())
            elif intent == "post_now":
                kind = act.get("kind") or "morning"
                make = {"week": lambda db: week_section(db, today()),
                        "evening": evening_post}.get(kind, morning_post)
                replies.append(make(self.hdb))
            elif intent == "help":
                replies.append(HOME_HELP)
            elif intent == "other" and act.get("reply"):
                replies.append(act["reply"][:400])
            if intent in MUTATORS:
                mutated.append(intent)
        if replies:
            await self.send(room_id, "\n".join(replies))
        if mutated:
            await asyncio.to_thread(git_snapshot, self.hdb, DB_PATH,
                                    f"{'+'.join(mutated)} by {sender}: {text[:60]}")

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
            # Reminders due now (or missed while down — fired late, once,
            # flagged with the time they were meant for).
            due_now = f"{day} {hhmm}"
            for r in pending_reminders(self.hdb):
                if r["at"] > due_now:
                    break  # sorted by at
                late = r["at"] < (now - timedelta(minutes=2)).strftime("%Y-%m-%d %H:%M")
                msg = (f"⏰ {'@' + r['assignee'] + ': ' if r['assignee'] else ''}{r['text']}"
                       f"{' (meant for ' + r['at'] + ')' if late else ''}")
                try:
                    await self.send(self.home_room, msg, notify=True,
                                    mention=r["assignee"] or "room")
                    self.hdb.execute("UPDATE reminder SET fired_ts=? WHERE id=?",
                                     (int(time.time()), r["id"]))
                    self.hdb.commit()
                except Exception:
                    log.exception("reminder %s failed", r["id"])
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
