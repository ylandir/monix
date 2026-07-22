"""Curtis: work-Discord bot for wholesale order lines and staff requests.

Slash commands (app_commands) plus interactive bits: /wholesale and
/request open modal entry forms; /orders and /requests list rows with an
inline ✓ button per open row. Checked-off rows stay in the lists, struck
through with who checked them, until /clear hides them. Nothing is ever
deleted: checking off stamps done_at/done_by, clearing stamps cleared_at.

Environment:
  DISCORD_TOKEN          bot token (required; never logged)
  CURTISBOT_DB           sqlite file path (default ./bot.db)
  CURTISBOT_TEST_DB      sandbox sqlite path (default ./test.db)
  DISCORD_GUILD_ID       the real guild id — sync commands there; its
                         interactions hit the real DB (instant sync;
                         unset = global sync, everything on the real DB)
  DISCORD_TEST_GUILD_ID  optional test guild id — commands sync there
                         too, but its interactions hit the sandbox DB
"""

import io
import math
import os
import re
import sqlite3
import sys
from datetime import datetime, timezone

import discord
from discord import app_commands

DB_PATH = os.environ.get("CURTISBOT_DB", "bot.db")
TEST_DB_PATH = os.environ.get("CURTISBOT_TEST_DB", "test.db")
GUILD_ID = os.environ.get("DISCORD_GUILD_ID", "").strip()
TEST_GUILD_ID = os.environ.get("DISCORD_TEST_GUILD_ID", "").strip()

SCHEMA = """
CREATE TABLE IF NOT EXISTS orders (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    account    TEXT NOT NULL,
    item       TEXT NOT NULL,
    amount     REAL NOT NULL,
    unit       TEXT NOT NULL,
    entered_by TEXT NOT NULL,
    created_at TEXT NOT NULL,
    done_at    TEXT,
    done_by    TEXT,
    cleared_at TEXT
);
CREATE TABLE IF NOT EXISTS requests (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    item         TEXT NOT NULL,
    requested_by TEXT NOT NULL,
    created_at   TEXT NOT NULL,
    start_date   TEXT,
    end_date     TEXT,
    done_at      TEXT,
    done_by      TEXT,
    cleared_at   TEXT
);
"""


def now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S")


def day(ts: str) -> str:
    return ts[:10]


def connect(path: str = DB_PATH) -> sqlite3.Connection:
    conn = sqlite3.connect(path)
    conn.row_factory = sqlite3.Row
    conn.executescript(SCHEMA)
    # Migrate databases created before later columns existed.
    cols = {r[1] for r in conn.execute("PRAGMA table_info(requests)")}
    for col in ("start_date", "end_date", "cleared_at"):
        if col not in cols:
            conn.execute(f"ALTER TABLE requests ADD COLUMN {col} TEXT")
    cols = {r[1] for r in conn.execute("PRAGMA table_info(orders)")}
    if "cleared_at" not in cols:
        conn.execute("ALTER TABLE orders ADD COLUMN cleared_at TEXT")
    conn.commit()
    return conn


def parse_date(s):
    """'' -> None; 'YYYY-MM-DD' -> normalized; anything else raises ValueError."""
    s = (s or "").strip()
    if not s:
        return None
    return datetime.strptime(s, "%Y-%m-%d").strftime("%Y-%m-%d")


def fmt_amount(x: float) -> str:
    return str(int(x)) if float(x).is_integer() else f"{x:g}"


def fmt_qty(amount, unit, item) -> str:
    """'25 lbs Sawmill', or just the item text for unparsed one-off lines."""
    if unit:
        return f"{fmt_amount(amount)} {unit} {item}"
    if amount == 1:
        return item
    return f"{fmt_amount(amount)} {item}"


ITEM_LINE = re.compile(r"^(\d+(?:\.\d+)?)\s+(\S+)\s+(.+)$")


def parse_item_line(line):
    """'25 lbs Sawmill' -> (25.0, 'lbs', 'Sawmill'); no leading number ->
    the whole line as the item (amount 1, no unit)."""
    line = line.strip()
    m = ITEM_LINE.match(line)
    if m and valid_amount(float(m.group(1))):
        return float(m.group(1)), m.group(2), m.group(3).strip()
    return 1.0, "", line


# ---- db operations (plain functions so they can be tested without Discord)


def add_order(conn, account, item, amount, unit, who):
    cur = conn.execute(
        "INSERT INTO orders (account, item, amount, unit, entered_by, created_at)"
        " VALUES (?, ?, ?, ?, ?, ?)",
        (account.strip(), item.strip(), amount, unit.strip(), who, now()),
    )
    conn.commit()
    return cur.lastrowid


def open_orders(conn, account=None):
    """Visible = not yet cleared; includes checked-off rows until /clear."""
    q = "SELECT * FROM orders WHERE cleared_at IS NULL"
    args = []
    if account is not None:
        q += " AND account = ? COLLATE NOCASE"
        args.append(account.strip())
    return conn.execute(q + " ORDER BY id", args).fetchall()


def check_order(conn, order_id, who):
    """Returns 'ok', 'missing', or the prior done_at if already checked."""
    row = conn.execute("SELECT done_at FROM orders WHERE id = ?", (order_id,)).fetchone()
    if row is None:
        return "missing"
    if row["done_at"] is not None:
        return row["done_at"]
    conn.execute(
        "UPDATE orders SET done_at = ?, done_by = ? WHERE id = ?", (now(), who, order_id)
    )
    conn.commit()
    return "ok"


def distinct_values(conn, column, prefix, open_only=False):
    assert column in ("account", "item")
    q = (
        f"SELECT {column}, MAX(id) AS latest FROM orders"
        f" WHERE {column} LIKE ? ESCAPE '\\' COLLATE NOCASE"
    )
    if open_only:
        q += " AND done_at IS NULL"
    q += f" GROUP BY lower(trim({column})) ORDER BY latest DESC LIMIT 25"
    escaped = prefix.replace("\\", "\\\\").replace("%", r"\%").replace("_", r"\_")
    return [r[column] for r in conn.execute(q, (f"%{escaped}%",)).fetchall()]


def add_request(conn, item, who, start=None, end=None):
    cur = conn.execute(
        "INSERT INTO requests (item, requested_by, created_at, start_date, end_date)"
        " VALUES (?, ?, ?, ?, ?)",
        (item.strip(), who, now(), start, end),
    )
    conn.commit()
    return cur.lastrowid


def open_requests(conn):
    """Visible = not yet cleared; includes checked-off rows until /clear."""
    return conn.execute(
        "SELECT * FROM requests WHERE cleared_at IS NULL ORDER BY id"
    ).fetchall()


def clear_done(conn):
    """Hide checked-off rows from the lists. Returns (orders, requests) counts."""
    ts = now()
    o = conn.execute(
        "UPDATE orders SET cleared_at = ? WHERE done_at IS NOT NULL"
        " AND cleared_at IS NULL",
        (ts,),
    ).rowcount
    r = conn.execute(
        "UPDATE requests SET cleared_at = ? WHERE done_at IS NOT NULL"
        " AND cleared_at IS NULL",
        (ts,),
    ).rowcount
    conn.commit()
    return o, r


def close_request(conn, req_id, who):
    row = conn.execute("SELECT done_at FROM requests WHERE id = ?", (req_id,)).fetchone()
    if row is None:
        return "missing"
    if row["done_at"] is not None:
        return row["done_at"]
    conn.execute(
        "UPDATE requests SET done_at = ?, done_by = ? WHERE id = ?", (now(), who, req_id)
    )
    conn.commit()
    return "ok"


# ---- formatting


def fmt_window(start, end):
    if start and end:
        return f"{start} → {end}"
    return start or ""


def order_text(r):
    return (
        f"**{r['account']}** — {fmt_qty(r['amount'], r['unit'], r['item'])}"
        f" · {r['entered_by']} · {day(r['created_at'])}"
    )


def request_text(r):
    # Legacy rows carried a free-text item; new ones are person+dates.
    item = f"{r['item']} · " if r["item"] else ""
    window = fmt_window(r["start_date"], r["end_date"])
    window = f" · {window}" if window else ""
    return f"{item}**{r['requested_by']}**{window}"


def flat_text(r, text):
    if r["done_at"] is not None:
        return f"{text(r)}  [✔ {r['done_by']}]"
    return text(r)


def render_orders(rows, heading):
    if not rows:
        return f"{heading}\nNothing open."
    return "\n".join([heading] + [flat_text(r, order_text) for r in rows])


def render_requests(rows):
    if not rows:
        return "No open requests."
    return "\n".join(["Open requests:"] + [flat_text(r, request_text) for r in rows])


# ---- discord plumbing

def valid_amount(amount: float) -> bool:
    return math.isfinite(amount) and 0 < amount <= 1_000_000


async def reply(interaction: discord.Interaction, text: str, filename: str = "list.txt"):
    """Send text, falling back to a file attachment past Discord's limit."""
    if len(text) <= 1900:
        await interaction.followup.send(text)
    else:
        buf = io.BytesIO(text.encode())
        await interaction.followup.send(
            "Too long for a message — attached.", file=discord.File(buf, filename)
        )


class CheckOffButton(
    discord.ui.DynamicItem[discord.ui.Button],
    template=r"egb:(?P<kind>req|ord):(?P<id>[0-9]+)",
):
    """A ✓ button that closes its row. custom_id-encoded, so it keeps
    working across bot restarts without any registered view state."""

    def __init__(self, kind: str, row_id: int):
        self.kind = kind
        self.row_id = row_id
        super().__init__(
            discord.ui.Button(
                label="✓",
                style=discord.ButtonStyle.success,
                custom_id=f"egb:{kind}:{row_id}",
            )
        )

    @classmethod
    async def from_custom_id(cls, interaction, item, match):
        return cls(match["kind"], int(match["id"]))

    async def callback(self, interaction: discord.Interaction):
        who = interaction.user.display_name
        close = close_request if self.kind == "req" else check_order
        result = close(db_for(interaction), self.row_id, who)
        if result == "missing":
            await interaction.response.send_message(
                "That row doesn't exist.", ephemeral=True
            )
            return
        # Messages from before the layout-component switch carry plain
        # content + a button row; just strike the text and drop the button.
        if interaction.message.content:
            view = discord.ui.View.from_message(interaction.message)
            for child in list(view.children):
                if getattr(child, "custom_id", None) == self.custom_id:
                    view.remove_item(child)
            await interaction.response.edit_message(view=view)
            return
        # Rebuild the message from its own components: the clicked row's
        # section becomes struck-through text; every other row keeps its
        # button. (No bot-side state — the message is the state.)
        view = discord.ui.LayoutView(timeout=None)
        for comp in interaction.message.components:
            if isinstance(comp, discord.components.SectionComponent):
                text = comp.components[0].content
                cid = getattr(comp.accessory, "custom_id", "") or ""
                if cid == f"egb:{self.kind}:{self.row_id}":
                    view.add_item(discord.ui.TextDisplay(f"~~{text}~~ ✅ {who}"))
                    continue
                m = self.template.match(cid)
                if m:
                    view.add_item(
                        discord.ui.Section(
                            discord.ui.TextDisplay(text),
                            accessory=CheckOffButton(m["kind"], int(m["id"])),
                        )
                    )
                else:
                    view.add_item(discord.ui.TextDisplay(text))
            elif isinstance(comp, discord.components.TextDisplay):
                view.add_item(discord.ui.TextDisplay(comp.content))
        await interaction.response.edit_message(view=view)
        if result != "ok":
            await interaction.followup.send(
                f"(that one was already checked off on {day(result)})",
                ephemeral=True,
            )


# Components-v2 messages have a 40-component budget; each row costs 3
# (section + text + button), so long lists chunk across messages.
ROWS_PER_MESSAGE = 12
MAX_BUTTON_ROWS = 48


def rows_view(kind, rows, heading=None):
    """Inline list: open rows get their ✓ button on the line; checked-off
    rows stay visible, struck through with who checked them."""
    view = discord.ui.LayoutView(timeout=None)
    if heading:
        view.add_item(discord.ui.TextDisplay(heading))
    text = order_text if kind == "ord" else request_text
    for r in rows:
        if r["done_at"] is not None:
            view.add_item(
                discord.ui.TextDisplay(f"~~{text(r)}~~ ✅ {r['done_by']}")
            )
        else:
            view.add_item(
                discord.ui.Section(
                    discord.ui.TextDisplay(text(r)),
                    accessory=CheckOffButton(kind, r["id"]),
                )
            )
    return view


async def send_row_list(interaction, kind, rows, heading, empty_text, filename):
    if not rows:
        await interaction.followup.send(empty_text)
        return
    if len(rows) > MAX_BUTTON_ROWS:
        text = render_orders(rows, heading) if kind == "ord" else render_requests(rows)
        await reply(interaction, text, filename)
        return
    for i in range(0, len(rows), ROWS_PER_MESSAGE):
        chunk = rows[i : i + ROWS_PER_MESSAGE]
        await interaction.followup.send(
            view=rows_view(kind, chunk, heading if i == 0 else None)
        )


class RequestModal(discord.ui.Modal, title="Request"):
    start = discord.ui.TextInput(
        label="Start date (YYYY-MM-DD)",
        placeholder="2026-08-02",
        max_length=10,
    )
    end = discord.ui.TextInput(
        label="End date (YYYY-MM-DD)",
        required=False,
        placeholder="leave empty for just the one day",
        max_length=10,
    )

    async def on_submit(self, interaction: discord.Interaction):
        try:
            start = parse_date(str(self.start))
            end = parse_date(str(self.end))
        except ValueError:
            await interaction.response.send_message(
                "Dates must look like 2026-07-22 (YYYY-MM-DD).", ephemeral=True
            )
            return
        if end and end < start:
            await interaction.response.send_message(
                f"End date {end} is before start date {start}.", ephemeral=True
            )
            return
        who = interaction.user.display_name
        add_request(db_for(interaction), "", who, start, end)
        await interaction.response.send_message(
            f"Request added: **{who}** · {fmt_window(start, end)}"
        )


class WholesaleModal(discord.ui.Modal, title="Wholesale order"):
    account = discord.ui.TextInput(label="Account name", max_length=100)
    items = discord.ui.TextInput(
        label="Items (one per line)",
        style=discord.TextStyle.paragraph,
        placeholder="25 lbs Sawmill\n2 cases Ethiopia Guji\nlines without a leading number are fine too",
        max_length=1500,
    )

    async def on_submit(self, interaction: discord.Interaction):
        account = str(self.account).strip()
        item_lines = [l for l in str(self.items).splitlines() if l.strip()]
        if not account or not item_lines:
            await interaction.response.send_message(
                "Need an account name and at least one item line.", ephemeral=True
            )
            return
        who = interaction.user.display_name
        d = db_for(interaction)
        rows = []
        for line in item_lines:
            amount, unit, item = parse_item_line(line)
            oid = add_order(d, account, item, amount, unit, who)
            rows.append({"id": oid, "text": fmt_qty(amount, unit, item)})
        lines = [f"**{account}** — logged by {who}:"]
        lines += [f"- {r['text']}" for r in rows]
        await interaction.response.send_message("\n".join(lines))


class Bot(discord.Client):
    def __init__(self):
        super().__init__(intents=discord.Intents.default())
        self.tree = app_commands.CommandTree(self)

    async def setup_hook(self):
        self.add_dynamic_items(CheckOffButton)
        guild_ids = [g for g in (GUILD_ID, TEST_GUILD_ID) if g]
        if not guild_ids:
            await self.tree.sync()
            return
        for gid in guild_ids:
            guild = discord.Object(id=int(gid))
            self.tree.copy_global_to(guild=guild)
            try:
                await self.tree.sync(guild=guild)
            except discord.Forbidden:
                # Not (yet) invited there. Fatal for the real guild —
                # crash so systemd retries until the invite lands — but
                # the test guild is optional.
                if gid == GUILD_ID:
                    raise
                print(f"test guild {gid}: bot not invited, skipping sync",
                      file=sys.stderr)


bot = Bot()
main_db = None  # both set in main()
test_db = None


def db_for(interaction) -> sqlite3.Connection:
    """Route the real guild to the real DB; anywhere else (the test
    guild, DMs) hits the sandbox DB so experiments never mix with work."""
    if not GUILD_ID or str(interaction.guild_id) == GUILD_ID:
        return main_db
    return test_db


async def account_autocomplete(interaction, current: str):
    return [
        app_commands.Choice(name=v[:100], value=v[:100])
        for v in distinct_values(db_for(interaction), "account", current)
    ]


@bot.tree.command(description="Log a wholesale order (opens a form)")
async def wholesale(interaction: discord.Interaction):
    await interaction.response.send_modal(WholesaleModal())


@bot.tree.command(description="List open (unchecked) wholesale order lines")
@app_commands.describe(account="Only this account (optional)")
@app_commands.autocomplete(account=account_autocomplete)
async def orders(interaction: discord.Interaction, account: str | None = None):
    await interaction.response.defer()
    rows = open_orders(db_for(interaction), account)
    heading = "Open order lines" + (f" — {account.strip()}" if account else "") + ":"
    await send_row_list(
        interaction, "ord", rows, heading, f"{heading}\nNothing open.", "orders.txt"
    )


@bot.tree.command(description="Request a day or date range (opens a form)")
async def request(interaction: discord.Interaction):
    await interaction.response.send_modal(RequestModal())


@bot.tree.command(description="List open requests")
async def requests(interaction: discord.Interaction):
    await interaction.response.defer()
    rows = open_requests(db_for(interaction))
    await send_row_list(
        interaction, "req", rows, "Open requests:", "No open requests.", "requests.txt"
    )


@bot.tree.command(description="Clear checked-off rows out of the lists")
async def clear(interaction: discord.Interaction):
    await interaction.response.defer()
    o, r = clear_done(db_for(interaction))
    await interaction.followup.send(
        f"Cleared {o} checked-off order line{'s' if o != 1 else ''}"
        f" and {r} request{'s' if r != 1 else ''}."
        " (History is kept — nothing is deleted.)"
    )


def main():
    global main_db, test_db
    token = os.environ.get("DISCORD_TOKEN")
    if not token:
        print("DISCORD_TOKEN not set", file=sys.stderr)
        sys.exit(1)
    main_db = connect(DB_PATH)
    test_db = connect(TEST_DB_PATH)
    bot.run(token)


if __name__ == "__main__":
    main()
