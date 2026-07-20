"""remy — the family's household chat bot.

One bot, three rooms, room-scoped skills:

  - "Household" (created by the bot on first start, family invited):
    tasks with due dates and named lists in plain language ("we need to
    take the car in by Friday", "add milk and eggs to shopping"), plus a
    morning plan (07:00, with a rest-of-the-week section through Sunday)
    and evening report (19:00, with a week-ahead section on Sunday for
    the Monday–Sunday week starting next day), folding in the family
    calendar (calendar.json, written by the separate remy-calendar-sync
    unit — this process never leaves loopback).

  - "Scratchpad" (created on first start with scratch users configured,
    captain only): the household skill set against its OWN database
    (scratch.db) — notes, reminders, tasks, quick lists. The calendar is
    READ-only from here: summaries show it, but nothing mirrors to CalDAV
    and cal_add is refused. No scheduled posts (reminders still fire;
    summaries on demand).

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
import html
import io
import json
import logging
import os
import re
import sqlite3
import subprocess
import time
from datetime import date, datetime, timedelta
from functools import partial
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
SCRATCH_ROOM_NAME = os.environ.get("BOT_SCRATCH_ROOM_NAME", "Scratchpad")
SCRATCH_USERS = [u for u in os.environ.get("BOT_SCRATCH_USERS", "").split(",") if u]
SCRATCH_DB_PATH = os.environ.get("BOT_SCRATCH_DB", "/var/lib/remy/scratch.db")
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
# The family log: an append-only markdown journal the bot writes once a day.
# It lives in the state dir (a separate unit mirrors it into the Obsidian
# vault — the fenced bot can't reach /home). LOG_FLAG pokes that mirror.
LOG_PATH = os.environ.get("BOT_LOG", os.path.join(os.path.dirname(DB_PATH), "log.md"))
LOG_FLAG = os.path.join(os.path.dirname(DB_PATH), "log.flag")
LOG_TIME = os.environ.get("BOT_LOG_TIME", "23:50")

DEFAULT_CATEGORIES = [
    "groceries", "dining", "transport", "household", "health",
    "entertainment", "utilities", "clothing", "gifts", "travel", "other",
]

START_MS = int(time.time() * 1000)


# ---------------------------------------------------------------- databases

class Conn(sqlite3.Connection):
    # .cal: whether this database may WRITE to the family calendar (cal_add
    # plus task/reminder mirroring). True for the household; the scratchpad
    # is calendar-read-only — its views show events, but everything
    # downstream of queue_cal no-ops.
    cal = True


def connect(path):
    # check_same_thread=False: llm parsing reads via asyncio.to_thread while
    # the event loop owns writes; CPython's sqlite3 is built in serialized
    # threading mode, so sharing one connection across threads is safe.
    db = sqlite3.connect(path, check_same_thread=False, factory=Conn)
    db.row_factory = sqlite3.Row
    return db


def home_db(path=DB_PATH, cal=True):
    # The scratchpad reuses this whole organizer schema against its own
    # file, just with the calendar unwired.
    db = connect(path)
    db.cal = cal
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
            seq INTEGER NOT NULL DEFAULT 0, -- per-list display number, stable
            due TEXT NOT NULL DEFAULT '',       -- ISO yyyy-mm-dd, '' = undated
            assignee TEXT NOT NULL DEFAULT '',  -- '' = whole household
            section TEXT NOT NULL DEFAULT '',   -- a labelled group within a list
            added_by TEXT NOT NULL,
            added_ts INTEGER NOT NULL,
            done_ts INTEGER,                -- NULL = still needed
            done_by TEXT NOT NULL DEFAULT '',
            deleted INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS log_note(
            id INTEGER PRIMARY KEY,
            day TEXT NOT NULL,              -- yyyy-mm-dd this note belongs to
            text TEXT NOT NULL,
            added_by TEXT NOT NULL,
            added_ts INTEGER NOT NULL,
            deleted INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS cal_outbox(
            id INTEGER PRIMARY KEY,
            op TEXT NOT NULL DEFAULT 'create',  -- create | delete
            uid TEXT NOT NULL DEFAULT '',   -- iCalendar UID (deterministic for mirrors)
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
    # Migrations for databases created earlier on 2026-07-13.
    if "assignee" not in [r[1] for r in db.execute("PRAGMA table_info(task)")]:
        db.execute("ALTER TABLE task ADD COLUMN assignee TEXT NOT NULL DEFAULT ''")
    outbox_cols = [r[1] for r in db.execute("PRAGMA table_info(cal_outbox)")]
    if "op" not in outbox_cols:
        db.execute("ALTER TABLE cal_outbox ADD COLUMN op TEXT NOT NULL DEFAULT 'create'")
        db.execute("ALTER TABLE cal_outbox ADD COLUMN uid TEXT NOT NULL DEFAULT ''")
    # 2026-07-20 unified list model: items gained due/assignee/section/done_by,
    # and the separate `task` table folds into a plain list called "to-dos"
    # (a to-do is just a list item that may carry a due date). The old table
    # is kept for history/rollback but no longer read.
    item_cols = [r[1] for r in db.execute("PRAGMA table_info(item)")]
    for col in ("due", "assignee", "section", "done_by"):
        if col not in item_cols:
            db.execute(f"ALTER TABLE item ADD COLUMN {col} TEXT NOT NULL DEFAULT ''")
    if "seq" not in item_cols:
        db.execute("ALTER TABLE item ADD COLUMN seq INTEGER NOT NULL DEFAULT 0")
    db.commit()
    if meta_get(db, "merged_v2") != "1":
        for t in db.execute("SELECT * FROM task").fetchall():
            db.execute(
                "INSERT INTO item(list_name,name,due,assignee,section,added_by,"
                "added_ts,done_ts,done_by,deleted) VALUES('to-dos',?,?,?,'',?,?,?,?,?)",
                (t["title"], t["due"], t["assignee"], t["created_by"], t["created_ts"],
                 t["done_ts"], t["done_by"], t["deleted"]))
            new_id = db.execute("SELECT last_insert_rowid() r").fetchone()["r"]
            # An open dated to-do already has a calendar mirror under its old
            # task uid; move it to the item uid so future edits stay in sync.
            if db.cal and not t["deleted"] and t["done_ts"] is None and t["due"]:
                queue_cal(db, "delete", task_uid(t["id"]))
                queue_cal(db, "create", item_uid(new_id),
                          f"☐ {t['title']}" + (f" — {t['assignee']}" if t["assignee"] else ""),
                          t["due"], t["created_by"])
        meta_set(db, "merged_v2", "1")
    db.commit()
    # Per-list display numbers: number each list's OPEN items 1..N by id, so
    # what people see is always gap-free (retired rows are skipped, not
    # counted). Recomputed every start; the handlers re-run the same
    # compaction after each change. Retired rows get 0 so they never collide.
    db.execute("UPDATE item SET seq = (SELECT COUNT(*) FROM item i2 "
               "WHERE i2.list_name = item.list_name AND i2.deleted=0 "
               "AND i2.done_ts IS NULL AND i2.id <= item.id) "
               "WHERE deleted=0 AND done_ts IS NULL")
    db.execute("UPDATE item SET seq=0 WHERE deleted=1 OR done_ts IS NOT NULL")
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
        # the ledger's history stays one unbroken series. home.db and
        # scratch.db share /var/lib/remy/history under their own names.
        name = ("ledger.sql" if db_path == BUDGET_DB_PATH
                else os.path.basename(db_path).replace(".db", ".sql"))
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


def llm_text(system, text, max_tokens=700):
    """Free-form completion (no JSON schema) — used only to compose the daily
    log's prose. A little warmth is welcome here, so temperature is higher
    than the classifier's; callers must tolerate failure (the log falls back
    to a deterministic scaffold)."""
    body = {
        "model": LLM_MODEL,
        "messages": [{"role": "system", "content": system},
                     {"role": "user", "content": text}],
        "chat_template_kwargs": {"enable_thinking": False},
        "temperature": 0.3,
        "max_tokens": max_tokens,
    }
    resp = requests.post(LLM_URL, json=body, timeout=180)
    resp.raise_for_status()
    return resp.json()["choices"][0]["message"]["content"]


# ================================================================ household
# Tasks with due dates + named lists, and the scheduled day posts.

def open_items(db, list_name=None):
    """Open (undone, undeleted) items, optionally in one list. Dated items
    sort before undated within a list; sections group together."""
    q = "SELECT * FROM item WHERE deleted=0 AND done_ts IS NULL"
    args = ()
    if list_name is not None:
        q += " AND list_name=?"
        args = (list_name,)
    q += " ORDER BY list_name, section, CASE WHEN due='' THEN 1 ELSE 0 END, due, id"
    return db.execute(q, args).fetchall()


def dated_open(db):
    """Every open dated item, across all lists — the day's real commitments."""
    return db.execute(
        "SELECT * FROM item WHERE deleted=0 AND done_ts IS NULL AND due!='' "
        "ORDER BY due, id").fetchall()


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


def fmt_item(r):
    # Per-list number, clean list style ("1. milk"). Used only in single-list
    # views; cross-list summaries render names without numbers.
    return f"{r['seq']}. {r['name']}{fmt_who(r)}{fmt_due(r['due'])}"


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
        # Task/reminder mirror-events exist for the phone apps; the posts
        # already render those as tasks and reminders — don't echo them.
        uid = ev.get("uid", "")
        if (uid.startswith("remy-task-") or uid.startswith("remy-rem-")
                or uid.startswith("remy-item-")):
            continue
        try:
            d = date.fromisoformat(ev["start"][:10])
        except Exception:
            continue
        if day_from <= d <= day_to:
            out.append(ev)
    out.sort(key=lambda e: e["start"])
    # The source tag ("— dylan") only earns its ink when several named
    # calendars are in play; a single shared calendar tags nothing.
    if len({e.get("calendar") for e in out}) <= 1:
        out = [{**e, "calendar": ""} for e in out]
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
                   "enum": ["item_add", "item_done", "item_edit", "item_remove",
                            "item_restore", "list_show", "lists_show",
                            "list_rename", "list_clear", "todos_show",
                            "remind_add", "remind_cancel", "remind_show",
                            "cal_add", "log_add", "post_now", "help", "ask",
                            "other"]},
        "items": {"type": "array", "items": {"type": "string"}},
        "list_name": {"type": "string"},
        "new_list_name": {"type": "string"},
        "section": {"type": "string"},
        "due": {"type": "string"},
        "at": {"type": "string"},
        "rem_id": {"type": "integer"},
        "assignee": {"type": "string"},
        "item_id": {"type": "integer"},
        "new_name": {"type": "string"},
        "new_due": {"type": "string"},
        "new_assignee": {"type": "string"},
        "scope": {"type": "string",
                  "enum": ["today", "week", "all", "overdue", "done", ""]},
        "kind": {"type": "string", "enum": ["morning", "evening", "week", ""]},
        "text": {"type": "string"},
        "reply": {"type": "string"},
    },
    # Every field required: with a grammar-constrained lazy model, optional
    # fields simply never get emitted (budgetbot live finding). Unused
    # fields carry "" / 0 / [].
    "required": ["intent", "items", "list_name", "new_list_name", "section",
                 "due", "at", "rem_id", "assignee", "item_id", "new_name",
                 "new_due", "new_assignee", "scope", "kind", "text", "reply"],
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
    # Show the model the open lists grouped, each item as its per-list number
    # (the same number the user sees), so it can route and reference items.
    lists = {}
    for r in open_items(db):
        lists.setdefault(r["list_name"], []).append(r)
    if lists:
        listing = "\n".join(
            f"{ln}:\n" + "\n".join(f"  {r['seq']}. {r['name']}{fmt_who(r)}{fmt_due(r['due'])}"
                                   for r in rows)
            for ln, rows in lists.items())
    else:
        listing = "(no lists yet)"
    list_names = ", ".join(lists.keys()) or "(none yet)"
    deleted = "\n".join(f"[{r['list_name']}] {r['name']}" for r in db.execute(
        "SELECT * FROM item WHERE deleted=1 ORDER BY id DESC LIMIT 5"))
    reminders = "\n".join(fmt_reminder(r) for r in pending_reminders(db)) or "(none)"
    chat_desc = ("family household-organizer chat" if db.cal else
                 "personal scratchpad chat (one person and the bot: quick "
                 "notes, reminders, to-dos, lists)")
    cal_rule = """- An APPOINTMENT/EVENT that happens at a set time ("put the dentist on the
  calendar tuesday at 3", "gab's recital friday", "dinner with the smiths
  saturday 7pm") => cal_add with text = a short title and at ('yyyy-mm-dd HH:MM',
  or just 'yyyy-mm-dd' for all-day). Calendar = something HAPPENING at a time; a
  to-do = something to DO (maybe by a day); a reminder = a ping.
- "add to log ..." / "log that ..." / "for the log, ..." / "note in the log"
  => log_add with text = the thing to record (a vibe, a funny moment, something
  that happened today). The log is the family's daily journal.""" if db.cal else """- The calendar is READ-ONLY here (it shows in summaries, but events are added
  in the Household room): an appointment ("dentist tuesday at 3") => item_add
  to list "to-dos" with its due date, never cal_add. A keep-this jot ("note: the
  wifi password is X") => item_add with list_name "notes". "add to log" => log_add
  is a Household feature; here just item_add to "notes"."""
    system = f"""You classify one message from a {chat_desc} into a JSON list of actions.
A message may contain SEVERAL actions ("get milk, and remind me to call the vet
thursday" = item_add + remind_add) — emit one action object per thing, in message
order. Most messages are exactly one action.
Today is {now.isoformat()} ({now.strftime('%A')}) and the time right now is
{now_dt.strftime('%H:%M')} (24h) — resolve relative times ("in 5 minutes", "in an
hour") from that. Message author: {sender_name}. Family: [{", ".join(FAMILY)}].

The world is THREE buckets: LISTS (any number of named lists — shopping, chores,
to-dos, packing…; items may carry a due date and a person), the CALENDAR (timed
appointments), and REMINDERS (pings at a moment). "to-dos" is the catch-all list
for things to do; "chores" is its own list.

Open lists (each item shown as its per-list number — numbers restart per list,
so "2" in shopping is a different item than "2" in chores):
{listing}
Existing list names: {list_names}
Recently removed items (restorable), shown as [list] name:
{deleted or "(none)"}
Pending reminders (id time text):
{reminders}

Rules:
- Weeks run Monday–Sunday. "this week" = through the coming Sunday (inclusive);
  "next week" = the following Monday–Sunday; "the weekend" = the coming Sat/Sun.
- ADDING to a list ("add milk and eggs to shopping", "put batteries on the
  hardware list", "we need to renew the registration by friday", "dylan should
  call the plumber thursday", "remember to water the plants") => item_add.
  Fields: list_name (short, lowercase — reuse an existing name above when it
  fits); items = each thing separately, short, no dates/names inside; due as ISO
  yyyy-mm-dd if a day was given (today/tomorrow/EOD=today, a weekday = the NEXT
  such day, "" if none); assignee = one Family name if it's for one person
  ("I"/"me"/"remind me" = the author), else ""; section (lowercase) only if they
  put it in a named part of the list (e.g. recurring chores => list "chores"
  section "recurring"), else "".
  ROUTING: groceries/food with no list named => list_name "shopping"; a plain
  "we need to X" / "don't forget to X" / "add X" to-do with no list named =>
  list_name "to-dos". If a thing could sensibly go on more than one existing
  list and none was named, DO NOT GUESS — use intent ask (see below).
- Starting an empty list ("make a packing list") => item_add, that list_name,
  items [].
- REFERENCING an item: numbers are PER-LIST, so to act on one you MUST give BOTH
  its list_name AND item_id = its number within that list (from the lists above).
  Find it by name ("got the milk" => milk's list + its number) or by "N on/in
  <list>" ("done 2 on shopping" => list_name "shopping", item_id 2). If only a
  bare number is given and more than one list has it, DO NOT guess — use ask.
- Checking an item off ("got the milk", "did the plumber thing", "done 2 on
  shopping") => item_done with list_name + item_id.
- Rewording/redating/reassigning/moving ("push the dentist to friday", "give the
  milk to gab") => item_edit with list_name + item_id and only the changed
  new_name/new_due/new_assignee. Removing one => item_remove with list_name +
  item_id. Bringing one back ("restore the milk", "undo that") => item_restore
  with new_name = the removed item's name (from the removed list above) and
  list_name if a list was named — removed items are referenced by NAME, not a
  number.
- MANAGING lists: "show the shopping list" / "what's on chores" => list_show
  with list_name. "what lists do we have" / "show all my lists" => lists_show.
  "rename hardware to garage" => list_rename with list_name + new_list_name.
  "clear/delete the shopping list" => list_clear + list_name.
- Wanting a PING at a set moment ("remind me at 5 to leave", "remind us thursday
  at 9am to put the bins out") => remind_add with title... use field "text" for
  the thing (short) and at as 'yyyy-mm-dd HH:MM' 24h local (resolve like due
  dates; morning=09:00, noon=12:00, afternoon=15:00, evening/tonight=19:00; bare
  "at 5" after noon = 17:00). assignee like items. A DAY deadline with no clock
  time ("by friday") is an item_add to "to-dos", NOT a reminder. Cancel =>
  remind_cancel with rem_id; "what reminders are set" => remind_show.
{cal_rule}
- BROAD questions get the BROAD view: "what do we have to do today", "what's the
  day/week look like", "what's on today/this week", anything about THE CALENDAR
  => post_now (kind morning for today, week for the week). When torn between a
  summary and a narrow list, choose the summary.
- To-do questions: "what do I still have to do", "what's on my plate", "show my
  to-dos", "what got done" => todos_show with scope (today|week|all|overdue|done)
  and assignee when one person is named ("what do I have" = the author).
- Asking what you can do => help.
- UNSURE? If you genuinely cannot tell which list an item belongs to, or which
  item/list a command targets, DO NOT guess and DO NOT invent — use intent ask
  with reply = one short clarifying question ("Which list should 'gym bag' go
  on — packing, or to-dos?"). Prefer asking over a wrong guess.
- Anything else (greetings, chatter between the humans, unclear and not for the
  bot) => intent other with reply = a one-line response ONLY if the message was
  addressed to the bot, else reply "".
Every JSON field is required in every action: set unused string fields to "",
unused numbers to 0, unused arrays to []. For item_add, items MUST be filled in
(unless starting an empty list). Chatter not addressed to the bot = one "other"
action with reply "".
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
    text = (act.get("text") or "").strip()[:120]
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
    queue_cal(db, "create", rem_uid(r["id"]),
              f"⏰ {text}{' — ' + who if who else ''}", at, sender)
    return f"⏰ will do — {fmt_reminder(r)}"


OUTBOX_FLAG = os.path.join(os.path.dirname(DB_PATH), "outbox.flag")


def queue_cal(db, op, uid, summary="", start="", sender=""):
    """Queue a calendar create/delete and poke the credentialed sync unit
    (a systemd path unit watches the flag file); it hits Migadu within
    seconds. Tasks and reminders mirror onto the calendar through here
    with deterministic uids, so moving/finishing them updates the event.
    A calendar-less database (the scratchpad) mirrors nothing.
    """
    if not db.cal:
        return
    db.execute("INSERT INTO cal_outbox(op,uid,summary,start,created_by,created_ts)"
               " VALUES(?,?,?,?,?,?)", (op, uid, summary, start, sender, int(time.time())))
    db.commit()
    try:
        with open(OUTBOX_FLAG, "w") as f:
            f.write(str(time.time()))
    except OSError:
        log.exception("outbox flag write failed")  # 30-min timer still delivers


def task_uid(task_id):
    # Retained only so the one-time merge can retire the old task mirrors.
    return f"remy-task-{task_id}@remy.local"


def item_uid(item_id):
    return f"remy-item-{item_id}@remy.local"


def rem_uid(rem_id):
    return f"remy-rem-{rem_id}@remy.local"


def sync_item_event(db, item_id):
    """Make the calendar mirror match the item row: delete the old event,
    re-create if the item is open and dated (all-day on the due day). Only
    dated items ever reach the calendar."""
    r = db.execute("SELECT * FROM item WHERE id=?", (item_id,)).fetchone()
    queue_cal(db, "delete", item_uid(item_id))
    if r and not r["deleted"] and r["done_ts"] is None and r["due"]:
        queue_cal(db, "create", item_uid(item_id),
                  f"☐ {r['name']}{fmt_who(r)}", r["due"], r["added_by"])


def do_cal_add(db, act, sender):
    title = (act.get("text") or "").strip()[:120]
    at = valid_at(act.get("at")) or valid_date((act.get("at") or "").strip()[:10])
    if not title or not at:
        return "Put what on the calendar, when? ('dentist on the calendar tuesday at 3')"
    row_ts = int(time.time())
    db.execute("INSERT INTO cal_outbox(summary,start,created_by,created_ts)"
               " VALUES(?,?,?,?)", (title, at, sender, row_ts))
    db.commit()
    r = db.execute("SELECT id FROM cal_outbox ORDER BY id DESC LIMIT 1").fetchone()
    db.execute("UPDATE cal_outbox SET uid=? WHERE id=?",
               (f"remy-chat-{r['id']}-{row_ts}@remy.local", r["id"]))
    db.commit()
    try:
        with open(OUTBOX_FLAG, "w") as f:
            f.write(str(time.time()))
    except OSError:
        log.exception("outbox flag write failed")
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
    queue_cal(db, "delete", rem_uid(r["id"]))
    return f"🗑 cancelled {fmt_reminder(r)}"


def do_remind_show(db):
    rows = pending_reminders(db)
    return "Reminders set:\n" + ("\n".join("⏰ " + fmt_reminder(r) for r in rows)
                                 or "(none)")


def renumber(db, list_name):
    """Compact a list's OPEN items to 1..N by id so displayed numbers stay
    gap-free; retired rows get 0. Run after any change to the list."""
    for i, row in enumerate(db.execute(
            "SELECT id FROM item WHERE list_name=? AND deleted=0 AND done_ts IS NULL "
            "ORDER BY id", (list_name,)).fetchall(), 1):
        db.execute("UPDATE item SET seq=? WHERE id=?", (i, row["id"]))
    db.execute("UPDATE item SET seq=0 WHERE list_name=? AND (deleted=1 OR done_ts IS NOT NULL)",
               (list_name,))
    db.commit()


def get_open(db, act):
    """Resolve an item the way people refer to it: its list plus the number
    shown next to it. Open items only (numbers only ever label open items)."""
    ln = (act.get("list_name") or "").strip().lower()
    seq = act.get("item_id") or 0
    if not ln or not seq:
        return None
    return db.execute("SELECT * FROM item WHERE list_name=? AND seq=? AND deleted=0 "
                      "AND done_ts IS NULL", (ln, seq)).fetchone()


NEED_REF = ("Which item? Say its list and number (e.g. 'done 2 on shopping') "
            "or just name it ('got the milk').")


def do_item_add(db, act, sender):
    names = [n.strip()[:80] for n in act.get("items", []) if n.strip()]
    ln = (act.get("list_name") or "shopping").strip().lower()[:30]
    section = (act.get("section") or "").strip().lower()[:30]
    due = valid_date(act.get("due", ""))
    who = valid_assignee(act.get("assignee"))
    if not names:
        # "make a packing list": a list exists once something is on it, so
        # just teach the phrasing.
        return f"👍 '{ln}' it is — put things on it like 'add milk to {ln}'."
    now_ts = int(time.time())
    ids = []
    for n in names:
        db.execute("INSERT INTO item(list_name,name,due,assignee,section,added_by,added_ts)"
                   " VALUES(?,?,?,?,?,?,?)", (ln, n, due, who, section, sender, now_ts))
        ids.append(db.execute("SELECT last_insert_rowid() r").fetchone()["r"])
    db.commit()
    renumber(db, ln)
    if due:
        for i in ids:
            sync_item_event(db, i)
    n_open = db.execute("SELECT COUNT(*) c FROM item WHERE list_name=? AND deleted=0 "
                        "AND done_ts IS NULL", (ln,)).fetchone()["c"]
    tail = fmt_due(due) + (f" ({who})" if who else "")
    return f"✓ {', '.join(names)} → {ln}{tail} ({n_open} on the list)"


def do_item_done(db, act, sender):
    r = get_open(db, act)
    if not r:
        return NEED_REF
    db.execute("UPDATE item SET done_ts=?, done_by=? WHERE id=?",
               (int(time.time()), sender, r["id"]))
    db.commit()
    renumber(db, r["list_name"])
    if r["due"]:
        sync_item_event(db, r["id"])
    return f"✔ {r['name']} checked off {r['list_name']}"


def do_item_edit(db, act):
    r = get_open(db, act)
    if not r:
        return NEED_REF
    changes, params = [], []
    if act.get("new_name"):
        changes.append("name=?"); params.append(act["new_name"].strip()[:80])
    if act.get("new_due"):
        # A move also re-opens a done item ("push #3 to friday" implies not done).
        changes.append("due=?"); params.append(valid_date(act["new_due"]))
        changes.append("done_ts=NULL")
    if act.get("new_assignee"):
        changes.append("assignee=?"); params.append(valid_assignee(act["new_assignee"]))
    if not changes:
        return "Nothing to change that I understood."
    db.execute(f"UPDATE item SET {','.join(changes)} WHERE id=?", (*params, r["id"]))
    db.commit()
    renumber(db, r["list_name"])
    sync_item_event(db, r["id"])
    return "✏️ " + fmt_item(db.execute("SELECT * FROM item WHERE id=?", (r["id"],)).fetchone())


def do_item_remove(db, act):
    r = get_open(db, act)
    if not r:
        return NEED_REF
    db.execute("UPDATE item SET deleted=1 WHERE id=?", (r["id"],))
    db.commit()
    renumber(db, r["list_name"])
    if r["due"]:
        sync_item_event(db, r["id"])
    return f"🗑 removed {r['name']} from {r['list_name']} (say 'restore the {r['name']}' to undo)"


def do_item_restore(db, act):
    # Removed items no longer carry a live number, so bring one back by name
    # (most recent match), optionally scoped to a list.
    name = (act.get("new_name") or "").strip().lower()
    ln = (act.get("list_name") or "").strip().lower()
    q, args = "SELECT * FROM item WHERE deleted=1", []
    if ln:
        q += " AND list_name=?"; args.append(ln)
    if name:
        q += " AND lower(name) LIKE ?"; args.append(f"%{name}%")
    q += " ORDER BY id DESC LIMIT 1"
    r = db.execute(q, tuple(args)).fetchone()
    if not r:
        return "Nothing removed to bring back."
    db.execute("UPDATE item SET deleted=0 WHERE id=?", (r["id"],))
    db.commit()
    renumber(db, r["list_name"])
    r = db.execute("SELECT * FROM item WHERE id=?", (r["id"],)).fetchone()
    if r["due"]:
        sync_item_event(db, r["id"])
    return "↩️ restored " + fmt_item(r)


def do_list_show(db, act):
    ln = (act.get("list_name") or "").strip().lower()
    if not ln:
        return do_lists_show(db)
    rows = open_items(db, ln)
    if not rows:
        return f"'{ln}' is empty."
    lines, last_sec = [f"{ln}:"], None
    for r in rows:
        if r["section"] != last_sec:
            if r["section"]:
                lines.append(f"  [{r['section']}]")
            last_sec = r["section"]
        lines.append(f"  {fmt_item(r)}")
    return "\n".join(lines)


def do_lists_show(db):
    rows = db.execute(
        "SELECT list_name, COUNT(*) c FROM item WHERE deleted=0 AND done_ts IS NULL "
        "GROUP BY list_name ORDER BY list_name").fetchall()
    if not rows:
        return "No lists yet — start one like 'add milk to shopping'."
    return "Your lists:\n" + "\n".join(f"  • {r['list_name']} ({r['c']})" for r in rows)


def do_list_rename(db, act):
    ln = (act.get("list_name") or "").strip().lower()
    new = (act.get("new_list_name") or "").strip().lower()[:30]
    if not ln or not new:
        return "Rename which list to what? ('rename hardware to garage')"
    n = db.execute("UPDATE item SET list_name=? WHERE list_name=? AND deleted=0",
                   (new, ln)).rowcount
    db.commit()
    if not n:
        return f"No open list called '{ln}'."
    renumber(db, new)  # merged into a possibly-existing list — recompact it
    return f"✏️ '{ln}' → '{new}' ({n} item{'s' if n != 1 else ''})"


def do_list_clear(db, act):
    ln = (act.get("list_name") or "").strip().lower()
    if not ln:
        return "Clear which list?"
    n = db.execute("UPDATE item SET deleted=1 WHERE list_name=? AND deleted=0",
                   (ln,)).rowcount
    db.commit()
    renumber(db, ln)
    return f"🧹 cleared {ln} ({n} item{'s' if n != 1 else ''}; restorable from history)"


def do_todos_show(db, act):
    scope = act.get("scope") or "all"
    now = today()
    if scope == "done":
        rows = db.execute(
            "SELECT * FROM item WHERE list_name='to-dos' AND deleted=0 "
            "AND done_ts IS NOT NULL ORDER BY done_ts DESC LIMIT 10").fetchall()
        return "Recently done:\n" + ("\n".join(
            f"✔ {r['name']} ({r['done_by']})" for r in rows) or "(nothing yet)")
    rows = open_items(db, "to-dos")
    who = valid_assignee(act.get("assignee"))
    if who:
        # "what do I have" means mine PLUS the household's unassigned ones —
        # the whole point is what I could go do, not only what carries my name.
        rows = [r for r in rows if r["assignee"] in (who, "")]
    if scope == "today":
        rows = [r for r in rows if r["due"] and r["due"] <= now.isoformat()]
        head = "To-dos today (and overdue):"
    elif scope == "overdue":
        rows = [r for r in rows if r["due"] and r["due"] < now.isoformat()]
        head = "Overdue:"
    elif scope == "week":
        end = (now + timedelta(days=6 - now.weekday())).isoformat()
        rows = [r for r in rows if r["due"] and r["due"] <= end]
        head = "This week's to-dos:"
    else:
        head = "To-dos" + (f" — {who}" if who else "") + ":"
    return head + "\n" + ("\n".join(fmt_item(r) for r in rows) or "(nothing!)")


def do_log_add(db, act, sender):
    if not db.cal:
        return "The daily log lives in the Household room — add to it there."
    txt = (act.get("text") or "").strip()[:400]
    if not txt:
        return "Add what to the log? ('add to log: Julia had her baby today')"
    db.execute("INSERT INTO log_note(day,text,added_by,added_ts) VALUES(?,?,?,?)",
               (today().isoformat(), txt, sender, int(time.time())))
    db.commit()
    return f"📝 added to today's log — {txt}"


def week_section(db, start, title="📅 Week ahead:"):
    """From `start` through that week's Sunday (weeks run Monday–Sunday):
    calendar events by day, then the week's dated to-dos as their own list
    (captain's preference over inlining them into their due days)."""
    end = start + timedelta(days=6 - start.weekday())
    todos = [r for r in dated_open(db)
             if start.isoformat() <= r["due"] <= end.isoformat()]
    events, _ = calendar_events(start, end)
    if not todos and not events:
        return f"{title} clear so far."
    by_day = {}
    for ev in events:
        by_day.setdefault(ev["start"][:10], []).append("◦ " + fmt_event(ev))
    lines = [title]
    for d in sorted(by_day):
        lines.append(date.fromisoformat(d).strftime("%A %b %-d") + ":")
        lines += ["  " + s for s in by_day[d]]
    if todos:
        lines.append("To-dos due:")
        lines += [f"  • {r['name']}{fmt_who(r)}{fmt_due(r['due'])}" for r in todos]
    return "\n".join(lines)


def morning_post(db):
    now = today()
    lines = [f"☀️ {now.strftime('%A, %B %-d')}"]
    dated = dated_open(db)
    overdue = [r for r in dated if r["due"] < now.isoformat()]
    due_today = [r for r in dated if r["due"] == now.isoformat()]
    if overdue:
        lines.append("Overdue:")
        lines += [f"  • {r['name']}{fmt_who(r)}{fmt_due(r['due'])}" for r in overdue]
    if due_today:
        lines.append("Today:")
        lines += [f"  • {r['name']}{fmt_who(r)}" for r in due_today]
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
    if now.weekday() < 6:  # the rest of the week, through Sunday
        lines.append("")
        lines.append(week_section(db, now + timedelta(days=1),
                                  "📅 Rest of the week:"))
    return "\n".join(lines)


def evening_post(db):
    now = today()
    day_start = int(datetime.combine(now, datetime.min.time(), TZ).timestamp())
    lines = [f"🌙 Evening report — {now.strftime('%A')}"]
    done = db.execute(
        "SELECT * FROM item WHERE deleted=0 AND done_ts>=? ORDER BY done_ts",
        (day_start,)).fetchall()
    if done:
        lines.append("Done today:")
        lines += [f"  ✔ {r['name']} ({r['done_by']})" for r in done]
    missed = [r for r in dated_open(db) if r["due"] <= now.isoformat()]
    if missed:
        lines.append("Last call:")
        lines += [f"  • {r['name']}{fmt_who(r)}{fmt_due(r['due'])}" for r in missed]
    tomorrow = now + timedelta(days=1)
    due_tmrw = [r for r in dated_open(db) if r["due"] == tomorrow.isoformat()]
    events, _ = calendar_events(tomorrow, tomorrow)
    if due_tmrw or events:
        lines.append("Tomorrow:")
        lines += [f"  • {r['name']}{fmt_who(r)}" for r in due_tmrw]
        lines += ["  ◦ " + fmt_event(ev) for ev in events]
    if len(lines) == 1:
        lines.append("Quiet day — nothing logged, nothing due.")
    if now.weekday() == 6:  # Sunday: look at the week
        lines.append("")
        lines.append(week_section(db, tomorrow))
    return "\n".join(lines)


# ---------------------------------------------------------------- daily log

def fmt_clock(dt):
    """A datetime -> a friendly '10am' / '2:30pm'."""
    ap = dt.strftime("%p").lower()
    return f"{dt.strftime('%-I')}{ap}" if dt.minute == 0 else f"{dt.strftime('%-I:%M')}{ap}"


def build_day_log(db, day):
    """The day's raw material for the log: (itinerary_lines, done, notes).

    itinerary = timed calendar events + reminders that fired, in time order;
    done = items checked off that day; notes = what people dropped in with
    'add to log'. All deterministic — no model involved here.
    """
    d_iso = day.isoformat()
    day_start = int(datetime.combine(day, datetime.min.time(), TZ).timestamp())
    day_end = day_start + 86400
    entries = []  # (sortkey, text)
    events, _ = calendar_events(day, day)
    for ev in events:
        s = ev["start"]
        summ = ev.get("summary", "(untitled)")
        if len(s) > 10:
            t = datetime.fromisoformat(s).astimezone(TZ)
            entries.append((t.strftime("%H:%M"), f"{fmt_clock(t)} — {summ}"))
        else:
            entries.append(("zz", f"all day — {summ}"))
    for r in db.execute(
            "SELECT * FROM reminder WHERE deleted=0 AND fired_ts>=? AND fired_ts<? ORDER BY at",
            (day_start, day_end)).fetchall():
        hhmm = r["at"][11:]
        clock = fmt_clock(datetime.strptime(hhmm, "%H:%M")) if hhmm else "reminder"
        entries.append((hhmm or "zz", f"{clock} — {r['text']}"))
    entries.sort(key=lambda x: x[0])
    done = [r["name"] for r in db.execute(
        "SELECT * FROM item WHERE deleted=0 AND done_ts>=? AND done_ts<? ORDER BY done_ts",
        (day_start, day_end)).fetchall()]
    notes = [r["text"] for r in db.execute(
        "SELECT text FROM log_note WHERE day=? AND deleted=0 ORDER BY id", (d_iso,)).fetchall()]
    return [e[1] for e in entries], done, notes


LOG_SYS = """You are writing one day's entry in a family's shared daily log — a
warm, human record of the day. You get: the day's itinerary (timed things, in
order), what got done, and freeform notes people dropped in chat. Produce
GitHub-flavored markdown for the body only (a date heading is added for you).
Rules, followed exactly:
- Render the itinerary as a bulleted list, in the given order and wording
  ("- 10am — meet with Julia").
- If a note clearly refers to one itinerary line (same person or event), attach
  it as an indented sub-bullet under that line ("  - she just had her baby").
  Notes that don't match any line go under a final "- also:" bullet.
- If the notes convey the day's overall mood or a noteworthy moment, end with ONE
  italic sentence capturing it. If they don't, add nothing.
- Invent NOTHING — use only the facts given. No date heading.
Output only the markdown body."""


def build_day_markdown(db, day):
    timed, done, notes = build_day_log(db, day)
    header = f"## {day.strftime('%A, %B %-d, %Y')}"
    if not timed and not done and not notes:
        return f"{header}\n\nQuiet one — nothing on the books.\n"
    scaffold = [f"- {t}" for t in timed] + [f"- did: {d}" for d in done]
    plain = header + "\n\n" + "\n".join(scaffold) + "\n"
    if not notes:
        return plain
    # Notes are what make a day read like a day — hand the scaffold + notes to
    # the local model to weave them in and add a closing line. Fall back to the
    # plain scaffold (notes listed) if the model is unavailable or misbehaves.
    payload = ("Itinerary (in order):\n" + ("\n".join(f"- {t}" for t in timed) or "- (nothing timed)")
               + "\n\nGot done:\n" + ("\n".join(f"- {d}" for d in done) or "- (nothing logged)")
               + "\n\nNotes from chat:\n" + "\n".join(f"- {n}" for n in notes))
    try:
        out = llm_text(LOG_SYS, payload).strip()
        if out:
            return header + "\n\n" + out + "\n"
    except Exception:
        log.exception("log compose failed; using scaffold")
    return plain + "Notes:\n" + "\n".join(f"- {n}" for n in notes) + "\n"


def write_log(db, day):
    """Append the day's entry to the log file and poke the vault mirror."""
    md = build_day_markdown(db, day)
    new_file = not os.path.exists(LOG_PATH) or os.path.getsize(LOG_PATH) == 0
    with open(LOG_PATH, "a") as f:
        if new_file:
            f.write("# Family log\n\n")
        else:
            f.write("\n")
        f.write(md)
    try:
        os.chmod(LOG_PATH, 0o644)  # the mirror unit (a different user) reads it
    except OSError:
        pass
    try:
        with open(LOG_FLAG, "w") as f:
            f.write(str(time.time()))
    except OSError:
        log.exception("log flag write failed")


HOME_HELP = """I keep the family organized around three things — lists, the
calendar, and reminders — plus a daily log. Examples:
• add milk and eggs to shopping / got the milk / show the shopping list
• make a packing list / what lists do we have? / rename hardware to garage
• we need to renew the registration by friday / I need dylan to call the plumber thursday
• what do I still have to do? / what's on gab's plate this week? / got the milk / done 2 on shopping
• remind me thursday at 9 to defrost the chicken / what reminders are set?
• put the dentist on the calendar tuesday at 3 — goes straight to Migadu
• add to log: Julia had her baby today — I write the day's log each night
• what's on today? / this week? — morning/evening summaries post at 7:00 and 19:00
If I'm not sure which list something belongs on, I'll ask.
(Money things live in the Budget room — I answer there too.)"""

SCRATCH_HELP = """Your scratchpad — notes, reminders, to-dos, quick lists. Examples:
• note: the gate code is 4482 / show the notes list
• remind me at 5 to leave / remind me thursday at 9 to call back / what reminders are set?
• renew the passport by friday / what do I still have to do? / done 3 on to-dos
• add batteries to hardware / what lists do we have?
Summaries show the family calendar, but it's read-only from here —
add events in the Household room. No scheduled posts; ask when you
want a summary."""


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
        "new_date": {"type": "string"},
        "query_kind": {"type": "string",
                       "enum": ["month_summary", "category_total", "recent", "compare_months"]},
        "month": {"type": "string"},
        "chart_kind": {"type": "string", "enum": ["month_bar", "trend"]},
        "reply": {"type": "string"},
    },
    "required": ["intent", "payee", "amount", "category", "date", "note",
                  "tx_id", "new_amount", "new_category", "new_payee", "new_date",
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
    if act.get("new_date"):
        changes.append("date=?"); params.append(act["new_date"])
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
        self.sdb = home_db(SCRATCH_DB_PATH, cal=False) if SCRATCH_USERS else None
        self.bdb = budget_db()
        self.client = AsyncClient(HS_URL, USER_ID)
        self.home_room = None
        self.scratch_room = None

    async def send(self, room_id, text, notify=False, mention=None):
        # Scheduled posts are m.text (they should ping phones); command
        # replies are m.notice (quieter, and other bots ignore notices).
        # mention: a FAMILY localpart for a personal ping, or "room" for
        # everyone. A real mention is two things: m.mentions (the push
        # signal) AND a matrix.to pill in formatted_body (what clients
        # render/highlight) — plain "@name" text does neither.
        content = {"msgtype": "m.text" if notify else "m.notice", "body": text}
        if mention == "room":
            content["m.mentions"] = {"room": True}
        elif mention:
            domain = self.client.user_id.split(":", 1)[1]
            user_id = f"@{mention}:{domain}"
            content["m.mentions"] = {"user_ids": [user_id]}
            escaped = html.escape(text).replace("\n", "<br/>")
            pill = f'<a href="https://matrix.to/#/{user_id}">@{mention}</a>'
            content["format"] = "org.matrix.custom.html"
            content["formatted_body"] = escaped.replace(
                html.escape(f"@{mention}"), pill, 1)
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
            handler = partial(self.handle_home, self.hdb)
        elif self.scratch_room and room.room_id == self.scratch_room:
            handler = partial(self.handle_home, self.sdb)
        elif room.room_id == BUDGET_ROOM_ID:
            handler = self.handle_budget
        else:
            return
        # One processed-table (the household db) covers both rooms. Mark before
        # handling for deliberate at-most-once semantics: replaying after a
        # crash could duplicate household or budget mutations.
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

    async def handle_home(self, db, room_id, sender, event, text):
        try:
            acts = await asyncio.to_thread(home_parse, db, sender, text)
        except Exception:
            log.exception("parse failed")
            await self.send(room_id, "(I choked parsing that — try again?)")
            return
        log.info("%s %s: %r -> %s", "home" if db is self.hdb else "scratch",
                 sender, text, [a.get("intent") for a in acts])
        MUTATORS = ("item_add", "item_done", "item_edit", "item_remove",
                    "item_restore", "list_rename", "list_clear", "cal_add",
                    "remind_add", "remind_cancel", "log_add")
        replies, mutated = [], []
        for act in acts[:8]:  # runaway-parse backstop
            intent = act.get("intent")
            handlers = {
                "item_add": lambda a=act: do_item_add(db, a, sender),
                "item_done": lambda a=act: do_item_done(db, a, sender),
                "item_edit": lambda a=act: do_item_edit(db, a),
                "item_remove": lambda a=act: do_item_remove(db, a),
                "item_restore": lambda a=act: do_item_restore(db, a),
                "list_show": lambda a=act: do_list_show(db, a),
                "lists_show": lambda: do_lists_show(db),
                "list_rename": lambda a=act: do_list_rename(db, a),
                "list_clear": lambda a=act: do_list_clear(db, a),
                "todos_show": lambda a=act: do_todos_show(db, a),
                "cal_add": lambda a=act: (
                    do_cal_add(db, a, sender) if db.cal else
                    "(the calendar is read-only here — add events in the Household room)"),
                "remind_add": lambda a=act: do_remind_add(db, a, sender),
                "remind_cancel": lambda a=act: do_remind_cancel(db, a),
                "remind_show": lambda: do_remind_show(db),
                "log_add": lambda a=act: do_log_add(db, a, sender),
            }
            if intent in handlers:
                replies.append(handlers[intent]())
            elif intent == "post_now":
                kind = act.get("kind") or "morning"
                make = {"week": lambda d: week_section(d, today()),
                        "evening": evening_post}.get(kind, morning_post)
                replies.append(make(db))
            elif intent == "help":
                replies.append(HOME_HELP if db.cal else SCRATCH_HELP)
            elif intent in ("ask", "other") and act.get("reply"):
                replies.append(act["reply"][:400])
            if intent in MUTATORS:
                mutated.append(intent)
        if replies:
            await self.send(room_id, "\n".join(replies))
        if mutated:
            db_path = DB_PATH if db is self.hdb else SCRATCH_DB_PATH
            await asyncio.to_thread(git_snapshot, db, db_path,
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
            # The family log: composed once, late, for the day that's ending.
            # Household only (the scratchpad has no scheduled writes).
            if hhmm >= LOG_TIME and meta_get(self.hdb, "last_log") != day:
                meta_set(self.hdb, "last_log", day)
                try:
                    await asyncio.to_thread(write_log, self.hdb, now.date())
                except Exception:
                    log.exception("log write failed")
            # Reminders due now (or missed while down — fired late, once,
            # flagged with the time they were meant for). Household and
            # scratchpad each ping their own room.
            due_now = f"{day} {hhmm}"
            rooms = [(self.hdb, self.home_room)]
            if self.sdb and self.scratch_room:
                rooms.append((self.sdb, self.scratch_room))
            for db, room in rooms:
                for r in pending_reminders(db):
                    if r["at"] > due_now:
                        break  # sorted by at
                    late = r["at"] < (now - timedelta(minutes=2)).strftime("%Y-%m-%d %H:%M")
                    msg = (f"⏰ {'@' + r['assignee'] + ': ' if r['assignee'] else ''}{r['text']}"
                           f"{' (meant for ' + r['at'] + ')' if late else ''}")
                    try:
                        await self.send(room, msg, notify=True,
                                        mention=r["assignee"] or "room")
                        db.execute("UPDATE reminder SET fired_ts=? WHERE id=?",
                                   (int(time.time()), r["id"]))
                        db.commit()
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
        # The scratchpad: captain-only notes/reminders room, created the
        # same way (its id lives in the household meta table).
        self.scratch_room = meta_get(self.hdb, "scratch_room_id")
        if SCRATCH_USERS and not self.scratch_room:
            resp = await self.client.room_create(
                name=SCRATCH_ROOM_NAME,
                topic="Notes, reminders, and quick stuff — just us.",
                invite=SCRATCH_USERS,
                power_level_override={
                    "users": {self.client.user_id: 100, SCRATCH_USERS[0]: 100}},
            )
            if not getattr(resp, "room_id", None):
                raise SystemExit(f"scratchpad room create failed: {resp}")
            self.scratch_room = resp.room_id
            meta_set(self.hdb, "scratch_room_id", self.scratch_room)
            log.info("created room %s (%s)", SCRATCH_ROOM_NAME, self.scratch_room)
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
        log.info("remy up as %s (home %s, scratch %s, budget %s)",
                 USER_ID, self.home_room, self.scratch_room or "-",
                 BUDGET_ROOM_ID or "-")
        asyncio.get_event_loop().create_task(self.scheduler())
        await self.client.sync_forever(timeout=30000, full_state=True)


if __name__ == "__main__":
    asyncio.run(Bot().run())
