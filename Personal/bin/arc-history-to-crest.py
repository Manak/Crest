#!/usr/bin/env python3
"""Move Arc's browsing history into the Crest Spaces of the same name.

Each Arc Space keeps its history in the Chromium profile it belongs to. Crest's
core keeps each Space's history itself, newest first and at most 5000
addresses, in the ``history.<Space>`` part of its session checkpoint. This
pairs the two by Space name (``--map`` pairs differently named ones), quits
Crest, backs up its session store, and writes each Arc address as Crest
records it: once, with its first and latest visit, its visit count and its
latest title, merged with whatever Crest already has for the same address.
Crest keeps only the newest 5000 addresses of each Space, so an Arc history
longer than that is cut at the 5000 most recently visited. Crest is relaunched
afterwards. Pass ``--dry-run`` to see what would move without quitting Crest.
"""

import argparse
import datetime
import json
import pathlib
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time
import urllib.parse
import uuid

HOME = pathlib.Path.home()
ARC = HOME / "Library/Application Support/Arc"
CREST = HOME / "Library/Application Support/Crest"
CACHE = HOME / "Library/Caches/Crest-local-release"
SESSION = CREST / "ControlPlane/session.sqlite"

# What a Space's history holds (HistoryEntryState.MaximumEntries, ImportText.MaximumTitle).
MAXIMUM_ENTRIES = 5000
MAXIMUM_TITLE = 4096
# Chromium counts microseconds from 1601; Crest stores seconds from 2001.
CHROMIUM_TO_APPLE_SECONDS = 12_622_780_800


def arc_records(value):
    """Arc lists records as an array alternating identities and records, or as an object keyed by identity."""
    if isinstance(value, list):
        return [item for item in value if isinstance(item, dict)]
    if isinstance(value, dict):
        return [item for item in value.values() if isinstance(item, dict)]
    return []


def arc_spaces():
    """Each Arc Space's history store, by Space name."""
    sidebar = json.loads((ARC / "StorableSidebar.json").read_text())
    spaces = {}
    for container in arc_records(sidebar.get("sidebar", {}).get("containers")):
        for space in arc_records(container.get("spaces")):
            title = space.get("title")
            profile = space.get("profile") or {}
            if profile.get("default"):
                folder = "Default"
            else:
                folder = ((profile.get("custom") or {}).get("_0") or {}).get("directoryBasename")
            if title and folder and title not in spaces:
                spaces[title] = ARC / "User Data" / folder / "History"
    return spaces


def crest_spaces():
    """Each Crest Space's history part, by Space name."""
    with sqlite3.connect(f"file:{SESSION}?mode=ro", uri=True) as connection:
        row = connection.execute("SELECT data FROM checkpoint WHERE part = 'core'").fetchone()
    core = json.loads(bytes(row[0]))
    return {space["name"]: f"history.{space['id']['rawValue'].upper()}" for space in core["spaces"]}


def pair_spaces(overrides):
    """(Arc store, Crest part, name) for every Arc Space with a Crest Space of the same name or a mapped one."""
    arc = arc_spaces()
    crest = crest_spaces()
    folded = {name.casefold(): name for name in crest}
    pairs, unmatched = [], []
    for name, store in arc.items():
        target = overrides.get(name) or folded.get(name.casefold())
        if target in crest and store.exists():
            pairs.append((store, crest[target], f"{name} -> {target}"))
        else:
            unmatched.append(name)
    return pairs, unmatched


def snapshot(source, destination):
    """A consistent copy of a store the browser may be writing."""
    with sqlite3.connect(f"file:{source}?mode=ro", uri=True) as origin, sqlite3.connect(destination) as copy:
        origin.backup(copy)


def normalized(url):
    """The address Crest's history keeps for a page: an http or https address without its fragment, or None."""
    try:
        parts = urllib.parse.urlsplit(url)
    except ValueError:
        return None
    if parts.scheme not in ("http", "https") or not parts.netloc:
        return None
    return url.split("#", 1)[0]


def apple_seconds(chromium_microseconds):
    return chromium_microseconds / 1_000_000 - CHROMIUM_TO_APPLE_SECONDS


def arc_entries(store):
    """Every address Arc shows in its history, once, as (url, title, first, last, visits)."""
    entries = {}
    with sqlite3.connect(f"file:{store}?mode=ro", uri=True) as connection:
        rows = connection.execute(
            "SELECT u.url, u.title, u.visit_count, u.last_visit_time, MIN(v.visit_time)"
            " FROM urls u LEFT JOIN visits v ON v.url = u.id"
            " WHERE u.hidden = 0 AND u.last_visit_time > 0 AND (u.url LIKE 'http://%' OR u.url LIKE 'https://%')"
            " GROUP BY u.id")
        for url, title, visits, last, first in rows:
            address = normalized(url)
            if address is None:
                continue
            first = first if first and first <= last else last
            merge(entries, address, title or "", apple_seconds(first), apple_seconds(last), max(visits, 1))
    return entries


def merge(entries, url, title, first, last, visits):
    """One address's visits counted together: earliest first visit, latest last visit, the title of the latest."""
    existing = entries.get(url)
    if existing is None:
        entries[url] = {"url": url, "title": title, "first": first, "last": last, "visits": visits}
        return
    existing["visits"] += visits
    existing["first"] = min(existing["first"], first)
    if last >= existing["last"]:
        existing["last"] = last
        existing["title"] = title or existing["title"]


def crest_entries(connection, part):
    """Crest's current history for the Space, by address, keeping each entry's identity."""
    row = connection.execute("SELECT data FROM checkpoint WHERE part = ?", (part,)).fetchone()
    if row is None:
        sys.exit(f"Crest's session has no {part} part; is the Space new? Open Crest once first.")
    entries = {}
    for entry in json.loads(bytes(row[0])):
        entries[entry["url"]] = {"id": entry["id"], "url": entry["url"], "title": entry.get("title", ""),
                                 "first": entry["firstVisitedAt"], "last": entry["lastVisitedAt"],
                                 "visits": entry.get("visitCount", 1)}
    return entries


def combined(crest, arc):
    """Crest's history with Arc's folded in, newest first and cut to what a Space keeps."""
    entries = {url: dict(entry) for url, entry in crest.items()}
    for url, entry in arc.items():
        merge(entries, url, entry["title"], entry["first"], entry["last"], entry["visits"])
    kept = sorted(entries.values(), key=lambda entry: (-entry["last"], entry["url"]))[:MAXIMUM_ENTRIES]
    return [{
        "id": entry.get("id") or str(uuid.uuid4()).upper(),
        "url": entry["url"],
        "title": kept_title(entry),
        "firstVisitedAt": entry["first"],
        "lastVisitedAt": entry["last"],
        "visitCount": min(entry["visits"], 2**31 - 1),
    } for entry in kept]


def kept_title(entry):
    """A page saying nothing gets its host for a title, as Crest does on a visit."""
    title = entry["title"].strip() or urllib.parse.urlsplit(entry["url"]).hostname or entry["url"]
    return title[:MAXIMUM_TITLE]


def describe(entries):
    if not entries:
        return "nothing"
    epoch = datetime.datetime(2001, 1, 1, tzinfo=datetime.timezone.utc)
    oldest = (epoch + datetime.timedelta(seconds=min(entry["lastVisitedAt"] for entry in entries))).astimezone()
    newest = (epoch + datetime.timedelta(seconds=max(entry["lastVisitedAt"] for entry in entries))).astimezone()
    return f"{len(entries)} addresses last visited between {oldest:%Y-%m-%d} and {newest:%Y-%m-%d}"


def crest_running():
    return subprocess.run(["pgrep", "-f", "Crest.app/Contents/MacOS"], capture_output=True).returncode == 0


def quit_crest():
    if not crest_running():
        return
    subprocess.run(["osascript", "-e", 'tell application "Crest" to quit'], capture_output=True)
    for _ in range(60):
        if not crest_running():
            return
        time.sleep(1)
    sys.exit("Crest did not quit; nothing was changed.")


def count(part):
    with sqlite3.connect(f"file:{SESSION}?mode=ro", uri=True) as connection:
        row = connection.execute("SELECT data FROM checkpoint WHERE part = ?", (part,)).fetchone()
    return len(json.loads(bytes(row[0]))) if row else 0


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--map", action="append", default=[], metavar="ARC=CREST",
                        help="pair an Arc Space with a differently named Crest Space (repeatable)")
    parser.add_argument("--dry-run", action="store_true", help="report what would move; Crest keeps running")
    parser.add_argument("--no-relaunch", action="store_true", help="leave Crest closed afterwards")
    args = parser.parse_args()
    sys.stdout.reconfigure(line_buffering=True)
    overrides = dict(item.split("=", 1) for item in args.map if "=" in item)

    pairs, unmatched = pair_spaces(overrides)
    for name in unmatched:
        print(f"Skipping Arc Space {name!r}: no Crest Space of that name (use --map).")
    if not pairs:
        sys.exit("Nothing to move.")

    with tempfile.TemporaryDirectory(prefix="arc-history-") as scratch:
        scratch = pathlib.Path(scratch)
        plans = []
        with sqlite3.connect(f"file:{SESSION}?mode=ro", uri=True) as connection:
            for index, (arc_store, part, label) in enumerate(pairs):
                arc_copy = scratch / f"arc-{index}.sqlite"
                snapshot(arc_store, arc_copy)
                arc = arc_entries(arc_copy)
                crest = crest_entries(connection, part)
                entries = combined(crest, arc)
                print(f"{label}: Arc has {len(arc)} addresses, Crest has {len(crest)}; Crest would keep {describe(entries)}")
                plans.append((part, label, entries))
        if args.dry_run:
            return

        quit_crest()
        backup = CACHE / "history-backups" / datetime.datetime.now().strftime("%Y-%m-%d-%H%M%S")
        backup.mkdir(parents=True)
        for suffix in ("", "-wal", "-shm"):
            source = SESSION.with_name(SESSION.name + suffix)
            if source.exists():
                shutil.copy2(source, backup / source.name)
        print(f"Crest's session store is backed up in {backup}")

        with sqlite3.connect(SESSION) as connection:
            for part, label, entries in plans:
                # Crest reads the part as System.Text.Json wrote it: a compact array.
                data = json.dumps(entries, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
                connection.execute("UPDATE checkpoint SET data = ? WHERE part = ?", (data, part))
            connection.commit()
        for part, label, entries in plans:
            print(f"{label}: wrote {len(entries)} entries")

    if args.no_relaunch:
        return
    subprocess.run(["open", "-a", "Crest"], check=True)
    time.sleep(20)
    for part, label, entries in plans:
        kept = count(part)
        print(f"{label}: Crest kept {kept} of {len(entries)} entries after relaunch"
              + ("" if kept >= len(entries) else " (some were dropped)"))


if __name__ == "__main__":
    main()
