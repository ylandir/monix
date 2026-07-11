"""budgetbot — the family budget's chat interface.

Lives in one Matrix room. Family members type purchases in plain language
("costco 84.12", "gas 40 yesterday"); a ship-local LLM parses them into a
SQLite ledger; the bot confirms, answers questions ("how much on groceries
this month?"), renders charts, applies corrections, and nags when entries
go stale. Everything it talks to is on loopback: the homeserver (tuwunel),
the model (llama-swap), and the database file.

Design constraints:
  - Chat text is UNTRUSTED input. The LLM only ever classifies it into a
    fixed intent schema; SQL is always parameterized from typed fields;
    there is no path from message text to shell, SQL, or Matrix admin.
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
import time
from datetime import date, datetime, timedelta
from zoneinfo import ZoneInfo

import requests
from nio import AsyncClient, RoomMessageText

log = logging.getLogger("budgetbot")
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")

HS_URL = os.environ["BOT_HS_URL"]
USER_ID = os.environ["MATRIX_USER"]
PASSWORD = os.environ["MATRIX_PASSWORD"]
ROOM_ID = os.environ["BOT_ROOM_ID"]
LLM_URL = os.environ.get("LLM_URL", "http://127.0.0.1:8091/v1/chat/completions")
LLM_MODEL = os.environ.get("LLM_MODEL", "qwen3.6-35b-a3b")
DB_PATH = os.environ.get("BOT_DB", "/var/lib/budgetbot/budget.db")
TZ = ZoneInfo(os.environ.get("BOT_TZ", "America/New_York"))
REMIND_HOUR = int(os.environ.get("BOT_REMIND_HOUR", "18"))
STALE_DAYS = int(os.environ.get("BOT_STALE_DAYS", "3"))

DEFAULT_CATEGORIES = [
    "groceries", "dining", "transport", "household", "health",
    "entertainment", "utilities", "clothing", "gifts", "travel", "other",
]

START_MS = int(time.time() * 1000)


# ---------------------------------------------------------------- database

def db_connect():
    # check_same_thread=False: llm_parse reads via asyncio.to_thread while
    # the event loop owns writes; CPython's sqlite3 is built in serialized
    # threading mode, so sharing one connection across threads is safe.
    db = sqlite3.connect(DB_PATH, check_same_thread=False)
    db.row_factory = sqlite3.Row
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
            created_ts INTEGER NOT NULL
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


def categories(db):
    return [r["name"] for r in db.execute("SELECT name FROM categories ORDER BY name")]


def recent_tx(db, n=15):
    return db.execute("SELECT * FROM tx ORDER BY id DESC LIMIT ?", (n,)).fetchall()


def fmt_amount(cents):
    return f"${cents / 100:,.2f}"


def fmt_tx(r):
    return f"#{r['id']} {r['date']} {r['payee']} {fmt_amount(r['amount_cents'])} → {r['category']}"


# ---------------------------------------------------------------- LLM

INTENT_SCHEMA = {
    "type": "object",
    "properties": {
        "intent": {"type": "string",
                   "enum": ["add", "edit", "delete", "query", "chart",
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
    # Every field required: with a grammar-constrained lazy model, optional
    # fields simply never get emitted (live finding — payee came out "?").
    # Unused fields carry "" / 0 instead.
    "required": ["intent", "payee", "amount", "category", "date", "note",
                 "tx_id", "new_amount", "new_category", "new_payee",
                 "query_kind", "month", "chart_kind", "reply"],
}


def llm_parse(db, sender_name, text):
    today = datetime.now(TZ).date()
    recent = "\n".join(fmt_tx(r) for r in recent_tx(db)) or "(none)"
    system = f"""You classify one message from a family budget chat into a JSON action.
Today is {today.isoformat()} ({today.strftime('%A')}). Message author: {sender_name}.
Known categories: {", ".join(categories(db))}.
Recent transactions (id date payee amount category):
{recent}

Rules:
- A purchase mention ("costco 84.12", "40 on gas yesterday") => intent add.
  amount in dollars; date ISO (resolve words like yesterday/tuesday, default today);
  payee short and capitalized; pick the closest existing category ("other" if none fits).
- Correcting/changing an existing entry => intent edit, with tx_id from the list
  above and only the new_* fields being changed. Deleting one => intent delete + tx_id.
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
    body = {
        "model": LLM_MODEL,
        "messages": [{"role": "system", "content": system},
                     {"role": "user", "content": text}],
        "response_format": {"type": "json_schema",
                            "json_schema": {"name": "action", "schema": INTENT_SCHEMA}},
        # No thinking for a classification call: reasoning tokens count
        # against max_tokens and can starve the JSON entirely (bit us live);
        # this also cuts reply latency to ~a second.
        "chat_template_kwargs": {"enable_thinking": False},
        "temperature": 0.1,
        "max_tokens": 800,
    }
    resp = requests.post(LLM_URL, json=body, timeout=180)
    resp.raise_for_status()
    content = resp.json()["choices"][0]["message"]["content"]
    m = re.search(r"\{.*\}", content, re.S)
    return json.loads(m.group(0) if m else content)


# ---------------------------------------------------------------- actions

def do_add(db, act, sender, event_id):
    cents = round(float(act["amount"]) * 100)
    cat = act.get("category") or "other"
    if cat not in categories(db):
        cat = "other"
    day = act.get("date") or datetime.now(TZ).date().isoformat()
    payee = (act.get("payee") or "?").strip()[:80]
    db.execute(
        "INSERT INTO tx(date,payee,amount_cents,category,note,entered_by,event_id,created_ts)"
        " VALUES(?,?,?,?,?,?,?,?)",
        (day, payee, cents, cat, act.get("note", "")[:200], sender, event_id, int(time.time())))
    db.commit()
    r = db.execute("SELECT * FROM tx WHERE event_id=?", (event_id,)).fetchone()
    month_total = db.execute(
        "SELECT COALESCE(SUM(amount_cents),0) t FROM tx WHERE date LIKE ?",
        (day[:7] + "%",)).fetchone()["t"]
    return (f"✓ {fmt_amount(cents)} {payee} → {cat}"
            f"{'' if day == datetime.now(TZ).date().isoformat() else ' on ' + day}"
            f"  (#{r['id']}; {day[:7]} total {fmt_amount(month_total)})")


def do_edit(db, act):
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


def do_delete(db, act):
    r = db.execute("SELECT * FROM tx WHERE id=?", (act.get("tx_id"),)).fetchone()
    if not r:
        return "Couldn't tell which entry to delete — use its #id."
    db.execute("DELETE FROM tx WHERE id=?", (r["id"],))
    db.commit()
    return f"🗑 removed {fmt_tx(r)}"


def month_rows(db, month):
    return db.execute(
        "SELECT category, SUM(amount_cents) c FROM tx WHERE date LIKE ? "
        "GROUP BY category ORDER BY c DESC", (month + "%",)).fetchall()


def do_query(db, act):
    kind = act.get("query_kind", "month_summary")
    month = act.get("month") or datetime.now(TZ).date().isoformat()[:7]
    if kind == "recent":
        rows = recent_tx(db, 10)
        return "Recent:\n" + ("\n".join(fmt_tx(r) for r in rows) or "(nothing yet)")
    if kind == "category_total":
        cat = act.get("category") or "other"
        row = db.execute(
            "SELECT COALESCE(SUM(amount_cents),0) c, COUNT(*) n FROM tx "
            "WHERE date LIKE ? AND category=?", (month + "%", cat)).fetchone()
        return f"{month} {cat}: {fmt_amount(row['c'])} across {row['n']} entries"
    if kind == "compare_months":
        rows = db.execute(
            "SELECT substr(date,1,7) m, SUM(amount_cents) c FROM tx "
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
            "GROUP BY m ORDER BY m").fetchall()
        ax.plot([r["m"] for r in rows], [r["t"] for r in rows], marker="o")
        ax.set_title("Monthly spending")
        title = "trend.png"
    else:
        month = act.get("month") or datetime.now(TZ).date().isoformat()[:7]
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


HELP = """I file whatever you type into the ledger. Examples:
• costco 84.12 — logs a purchase (I guess the category)
• gas 40 yesterday / lunch 15 last tuesday
• change #12 to 84 / #12 was household / delete #12
• how much on groceries this month? / recent / monthly totals
• chart / trend — pictures
• add category kids"""


# ---------------------------------------------------------------- bot

class Bot:
    def __init__(self):
        self.db = db_connect()
        self.client = AsyncClient(HS_URL, USER_ID)

    async def send(self, text):
        await self.client.room_send(ROOM_ID, "m.room.message",
                                    {"msgtype": "m.notice", "body": text})

    async def send_image(self, name, buf):
        data = buf.getvalue()
        resp, _ = await self.client.upload(io.BytesIO(data), content_type="image/png",
                                           filename=name, filesize=len(data))
        if not getattr(resp, "content_uri", None):
            await self.send("(chart upload failed)")
            return
        await self.client.room_send(ROOM_ID, "m.room.message", {
            "msgtype": "m.image", "body": name, "url": resp.content_uri,
            "info": {"mimetype": "image/png", "size": len(data)},
        })

    async def on_message(self, room, event):
        if room.room_id != ROOM_ID or event.sender == self.client.user_id:
            return
        if self.db.execute("SELECT 1 FROM processed WHERE event_id=?",
                           (event.event_id,)).fetchone():
            return
        self.db.execute("INSERT INTO processed(event_id,ts) VALUES(?,?)",
                        (event.event_id, int(time.time())))
        self.db.commit()
        # Replay policy: catch up on messages missed while down (up to 7
        # days), but NEVER before this database first existed — a fresh DB
        # must not chew the room's prior history into duplicate entries.
        first_start = int(meta_get(self.db, "first_start_ms") or 0)
        if event.server_timestamp < max(first_start, START_MS - 7 * 86400 * 1000):
            return
        text = event.body.strip()
        if not text:
            return
        sender = event.sender.split(":")[0].lstrip("@")
        try:
            act = await asyncio.to_thread(llm_parse, self.db, sender, text)
        except Exception:
            log.exception("parse failed")
            await self.send("(I choked parsing that — try again?)")
            return
        log.info("%s: %r -> %s", sender, text, act.get("intent"))
        try:
            intent = act.get("intent")
            if intent == "add" and act.get("amount"):
                await self.send(do_add(self.db, act, sender, event.event_id))
            elif intent == "edit":
                await self.send(do_edit(self.db, act))
            elif intent == "delete":
                await self.send(do_delete(self.db, act))
            elif intent == "query":
                await self.send(do_query(self.db, act))
            elif intent == "chart":
                name, buf = await asyncio.to_thread(make_chart, self.db, act)
                await self.send_image(name, buf)
            elif intent == "add_category":
                cat = (act.get("category") or "").strip().lower()[:30]
                if cat:
                    self.db.execute(
                        "INSERT OR IGNORE INTO categories(name) VALUES(?)", (cat,))
                    self.db.commit()
                    await self.send(f"category '{cat}' added")
            elif intent == "help":
                await self.send(HELP)
            elif intent == "other" and act.get("reply"):
                await self.send(act["reply"][:400])
        except Exception:
            log.exception("action failed")
            await self.send("(something broke doing that — it's logged)")

    async def reminders(self):
        while True:
            await asyncio.sleep(600)
            now = datetime.now(TZ)
            if now.hour != REMIND_HOUR:
                continue
            today = now.date().isoformat()
            if meta_get(self.db, "last_reminder") == today:
                continue
            last = self.db.execute("SELECT MAX(date) d FROM tx").fetchone()["d"]
            stale = (not last or
                     (now.date() - date.fromisoformat(last)).days >= STALE_DAYS)
            if now.weekday() == 6:  # Sunday: month-to-date summary
                meta_set(self.db, "last_reminder", today)
                await self.send("Sunday check-in.\n" + do_query(self.db, {}))
            elif stale:
                meta_set(self.db, "last_reminder", today)
                days = "ever" if not last else f"since {last}"
                await self.send(f"No entries {days} — anything to log?")

    async def run(self):
        if not meta_get(self.db, "first_start_ms"):
            meta_set(self.db, "first_start_ms", str(START_MS))
        # Reuse a stored device/token when valid; else password login.
        tok, dev = meta_get(self.db, "access_token"), meta_get(self.db, "device_id")
        if tok and dev:
            self.client.restore_login(USER_ID, dev, tok)
            whoami = await self.client.whoami()
            if getattr(whoami, "user_id", None) != USER_ID:
                tok = None
        if not (tok and dev):
            resp = await self.client.login(PASSWORD, device_name="budgetbot")
            if not getattr(resp, "access_token", None):
                raise SystemExit(f"login failed: {resp}")
            meta_set(self.db, "access_token", resp.access_token)
            meta_set(self.db, "device_id", resp.device_id)
        await self.client.join(ROOM_ID)
        self.client.add_event_callback(self.on_message, RoomMessageText)
        log.info("budgetbot up as %s in %s", USER_ID, ROOM_ID)
        asyncio.get_event_loop().create_task(self.reminders())
        await self.client.sync_forever(timeout=30000, full_state=True)


if __name__ == "__main__":
    asyncio.run(Bot().run())
