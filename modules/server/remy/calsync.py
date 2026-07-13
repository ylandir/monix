"""remy-calendar-sync — the bot's two-way bridge to the family CalDAV.

Runs as a systemd timer (plus a path unit that fires it the moment the
bot queues an event), separate from the chat bot on purpose: this is
the ONLY remy process with network egress, and it holds the only copy
of the calendar credentials. Each run:

  1. PUSHES the bot's cal_outbox (events created from chat) to the FIRST
     configured calendar, marking rows pushed; a failed push stays queued
     and fails the unit (so it alerts) after the fetch still ran.
  2. FETCHES upcoming events (recurrences expanded) from each configured
     CalDAV account (Migadu: cdav.migadu.com) and atomically writes a
     normalized calendar.json that the loopback-fenced bot merely reads —
     so a just-pushed event is visible to the bot immediately. A broken
     fetch leaves the previous file in place.

Config: REMY_CALDAV_CONFIG points at a JSON file (an agenix secret):
  [{"name": "dylan", "url": "https://cdav.migadu.com/",
    "username": "dylan@...", "password": "..."}, ...]
"""

import json
import logging
import os
import sqlite3
import sys
import tempfile
import time
from datetime import date, datetime, timedelta, timezone
from zoneinfo import ZoneInfo

import caldav
import icalendar

log = logging.getLogger("calsync")
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")

CONFIG = os.environ["REMY_CALDAV_CONFIG"]
OUT = os.environ.get("BOT_CALENDAR_JSON", "/var/lib/remy/calendar.json")
DB_PATH = os.environ.get("BOT_DB", "/var/lib/remy/home.db")
TZ = ZoneInfo(os.environ.get("BOT_TZ", "America/New_York"))
DAYS_AHEAD = int(os.environ.get("REMY_CAL_DAYS", "30"))


def norm(component):
    """One VEVENT -> {start, end, summary} with ISO strings.

    date values (all-day) stay yyyy-mm-dd; datetimes keep their offset —
    the bot renders in ship-local time.
    """
    out = {}
    for src, dst in (("dtstart", "start"), ("dtend", "end")):
        v = component.get(src)
        if v is not None:
            out[dst] = v.dt.isoformat()
    out["summary"] = str(component.get("summary", "(untitled)"))
    return out if "start" in out else None


def fetch(cal_cfg, start, end):
    client = caldav.DAVClient(url=cal_cfg["url"], username=cal_cfg["username"],
                              password=cal_cfg["password"])
    events = []
    for cal in client.principal().calendars():
        # expand=True unrolls recurring events into concrete instances.
        for ev in cal.search(start=start, end=end, event=True, expand=True):
            for comp in ev.icalendar_instance.walk("VEVENT"):
                e = norm(comp)
                if e:
                    e["calendar"] = cal_cfg["name"]
                    events.append(e)
    return events


def push_outbox(cal_cfg):
    """Create the bot's queued events on the CalDAV server.

    Returns the number of rows that FAILED (left queued for the next run,
    error noted on the row).
    """
    if not os.path.exists(DB_PATH):
        return 0
    db = sqlite3.connect(DB_PATH)
    db.row_factory = sqlite3.Row
    failed = 0
    client = caldav.DAVClient(url=cal_cfg["url"], username=cal_cfg["username"],
                              password=cal_cfg["password"])
    # A principal can expose several collections (Migadu: calendars AND
    # journals — a VEVENT PUT into journals 403s; and more than one
    # event-capable collection, where "first with VEVENT" landed events in
    # a side collection the calendar UI never shows — both live findings).
    # Push to the collection that holds the family's actual events: the
    # VEVENT-capable one with the most events already in it.
    candidates = []
    for c in client.principal().calendars():
        try:
            if "VEVENT" not in (c.get_supported_components() or []):
                continue
            candidates.append((c, c.events()))
        except Exception:
            continue
    if not candidates:
        raise RuntimeError("no VEVENT-capable collection found")
    for c, evs in candidates:
        log.info("candidate collection %s: %d events", c.url, len(evs))
    calendar = max(candidates, key=lambda t: len(t[1]))[0]
    log.info("pushing to %s", calendar.url)
    # Sweep our strays out of the losing collections (the pre-fix pushes)
    # and requeue them so this same run re-creates them in the right one.
    for c, evs in candidates:
        if c.url == calendar.url:
            continue
        for ev in evs:
            try:
                uid = str(ev.icalendar_component.get("uid", ""))
                if uid.startswith("remy-"):
                    ev.delete()
                    db.execute("UPDATE cal_outbox SET pushed_ts=NULL WHERE id=?",
                               (int(uid.split("-")[1]),))
                    db.commit()
                    log.info("moved stray remy event out of %s", c.url)
            except Exception:
                log.exception("stray cleanup failed in %s", c.url)
    rows = db.execute(
        "SELECT * FROM cal_outbox WHERE pushed_ts IS NULL ORDER BY id").fetchall()
    for r in rows:
        try:
            ev = icalendar.Event()
            ev.add("uid", f"remy-{r['id']}-{r['created_ts']}@remy.local")
            ev.add("summary", r["summary"])
            if len(r["start"]) > 10:
                # UTC on the wire: a bare TZID with no VTIMEZONE component
                # is legal-ish and servers store it, but client UIs can
                # silently not render it. Every client renders Z-times.
                start = (datetime.strptime(r["start"], "%Y-%m-%d %H:%M")
                         .replace(tzinfo=TZ).astimezone(timezone.utc))
                ev.add("dtstart", start)
                ev.add("dtend", start + timedelta(hours=1))
            else:
                day = date.fromisoformat(r["start"])
                ev.add("dtstart", day)
                ev.add("dtend", day + timedelta(days=1))
            ev.add("dtstamp", datetime.now(TZ))
            cal = icalendar.Calendar()
            cal.add("prodid", "-//remy//household bot//EN")
            cal.add("version", "2.0")
            cal.add_component(ev)
            calendar.save_event(cal.to_ical().decode())
            db.execute("UPDATE cal_outbox SET pushed_ts=?, error='' WHERE id=?",
                       (int(time.time()), r["id"]))
            db.commit()
            log.info("pushed '%s' (%s)", r["summary"], r["start"])
        except Exception as e:
            failed += 1
            db.execute("UPDATE cal_outbox SET error=? WHERE id=?",
                       (str(e)[:200], r["id"]))
            db.commit()
            log.exception("push failed for '%s'", r["summary"])
    db.close()
    return failed


def main():
    with open(CONFIG) as f:
        calendars = json.load(f)
    push_failures = 0
    try:
        push_failures = push_outbox(calendars[0])
    except Exception:
        # Connection-level failure: everything stays queued for next run.
        push_failures = 1
        log.exception("outbox push failed")
    start = date.today() - timedelta(days=1)
    end = date.today() + timedelta(days=DAYS_AHEAD)
    events, failures = [], 0
    for cal_cfg in calendars:
        try:
            got = fetch(cal_cfg, start, end)
            events.extend(got)
            log.info("%s: %d events", cal_cfg["name"], len(got))
        except Exception:
            failures += 1
            log.exception("fetch failed for %s", cal_cfg.get("name", "?"))
    if failures == len(calendars):
        # Nothing fetched: keep the previous file (stale beats empty) and
        # fail the unit so the failure alerts to the Ship Alerts room.
        sys.exit(1)
    events.sort(key=lambda e: e["start"])
    payload = {"fetched_at": int(time.time()), "events": events}
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(OUT))
    with os.fdopen(fd, "w") as f:
        json.dump(payload, f, indent=1)
    os.replace(tmp, OUT)
    os.chmod(OUT, 0o644)
    log.info("wrote %d events to %s", len(events), OUT)
    if push_failures:
        # Fetch already ran and calendar.json is fresh; still fail the unit
        # so the stuck outbox rows alert instead of rotting silently.
        sys.exit(1)


if __name__ == "__main__":
    main()
