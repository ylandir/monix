"""remy-calendar-sync — pull the family's CalDAV calendars to a file.

Runs as a systemd timer, separate from the chat bot on purpose: this is
the ONLY remy process with network egress, and it holds the only copy
of the calendar credentials. It fetches upcoming events (recurrences
expanded) from each configured CalDAV account (Migadu: cdav.migadu.com)
and atomically writes a normalized calendar.json that the loopback-fenced
bot merely reads. A broken fetch leaves the previous file in place.

Config: REMY_CALDAV_CONFIG points at a JSON file (an agenix secret):
  [{"name": "dylan", "url": "https://cdav.migadu.com/",
    "username": "dylan@...", "password": "..."}, ...]
"""

import json
import logging
import os
import sys
import tempfile
import time
from datetime import date, timedelta

import caldav

log = logging.getLogger("calsync")
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")

CONFIG = os.environ["REMY_CALDAV_CONFIG"]
OUT = os.environ.get("BOT_CALENDAR_JSON", "/var/lib/remy/calendar.json")
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


def main():
    with open(CONFIG) as f:
        calendars = json.load(f)
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


if __name__ == "__main__":
    main()
