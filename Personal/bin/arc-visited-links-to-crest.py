#!/usr/bin/env python3
"""Merge Arc's Chromium history into Crest's engine profiles so visited links look visited.

Crest's own history lives in its core (``arc-history-to-crest.py`` moves that).
The Chromium engine under each Space keeps a second ``History`` database, and
builds the table that colors ``:visited`` links from its ``visited_links``
rows at startup. This pairs Arc Spaces with Crest Spaces by name (``--map``
pairs differently named ones), quits Crest, backs up each profile's
``History``, and merges the recent part of Arc's: the addresses, visits and
visited-link rows of the last ``--days`` days (90 by default, which is how
long Chromium keeps history before expiring it), with identities renumbered
and addresses Crest already knows folded together. Crest is relaunched
afterwards. Pass ``--dry-run`` to rehearse on copies without quitting Crest.
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

HOME = pathlib.Path.home()
ARC = HOME / "Library/Application Support/Arc"
CREST = HOME / "Library/Application Support/Crest"
CACHE = HOME / "Library/Caches/Crest-local-release"

# Chromium counts microseconds from 1601-01-01.
CHROMIUM_EPOCH_OFFSET_SECONDS = 11_644_473_600


def arc_records(value):
    """Arc lists records as an array alternating identities and records, or as an object keyed by identity."""
    if isinstance(value, list):
        return [item for item in value if isinstance(item, dict)]
    if isinstance(value, dict):
        return [item for item in value.values() if isinstance(item, dict)]
    return []


def arc_spaces():
    """Each Arc Space's Chromium history store, by Space name."""
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
    """Each Crest Space's Chromium history store, by Space name."""
    database = CREST / "ControlPlane/session.sqlite"
    with sqlite3.connect(f"file:{database}?mode=ro", uri=True) as connection:
        row = connection.execute("SELECT data FROM checkpoint WHERE part = 'core'").fetchone()
    core = json.loads(bytes(row[0]))
    return {space["name"]: CREST / "Chromium" / f"Crest-{space['profile']['id']}" / "History" for space in core["spaces"]}


def pair_spaces(overrides):
    """(Arc store, Crest store, name) for every Arc Space with a Crest Space of the same name or a mapped one."""
    arc = arc_spaces()
    crest = crest_spaces()
    folded = {name.casefold(): name for name in crest}
    pairs, unmatched = [], []
    for name, store in arc.items():
        target = overrides.get(name) or folded.get(name.casefold())
        if target in crest and store.exists() and crest[target].exists():
            pairs.append((store, crest[target], f"{name} -> {target}"))
        else:
            unmatched.append(name)
    return pairs, unmatched


def snapshot(source, destination):
    """A copy of a store the browser may hold open, with its rollback journal so SQLite settles it on open.

    Chromium keeps its stores exclusively locked while it runs, and SQLite's online backup waits on that lock
    forever, so this copies the files instead.
    """
    shutil.copy2(source, destination)
    journal = source.with_name(source.name + "-journal")
    if journal.exists() and journal.stat().st_size > 0:
        shutil.copy2(journal, destination.with_name(destination.name + "-journal"))
    else:
        pathlib.Path(str(destination) + "-journal").unlink(missing_ok=True)


def schema_version(connection, schema):
    return int(connection.execute(f"SELECT value FROM {schema}.meta WHERE key = 'version'").fetchone()[0])


def merge(crest_store, arc_copy, cutoff):
    """Fold Arc's history since `cutoff` (Chromium time) into Crest's store. Returns what was added."""
    with sqlite3.connect(crest_store) as db:
        db.execute("ATTACH DATABASE ? AS arc", (f"file:{arc_copy}?mode=ro",))
        if schema_version(db, "main") != schema_version(db, "arc"):
            sys.exit(f"History schema differs: Crest {schema_version(db, 'main')}, Arc {schema_version(db, 'arc')}; not merging.")
        db.execute("BEGIN")

        # Addresses: those visited in the window, matched to Crest's rows by spelling.
        arc_urls = db.execute(
            "SELECT id, url, title, visit_count, typed_count, last_visit_time, hidden FROM arc.urls"
            " WHERE last_visit_time >= ? OR id IN (SELECT url FROM arc.visits WHERE visit_time >= ?)", (cutoff, cutoff)).fetchall()
        existing = {url: (row_id, visit_count, typed_count, last_visit_time) for row_id, url, visit_count, typed_count, last_visit_time
                    in db.execute("SELECT id, url, visit_count, typed_count, last_visit_time FROM main.urls")}
        url_map, new_urls = {}, []
        next_url_id = (db.execute("SELECT MAX(id) FROM main.urls").fetchone()[0] or 0) + 1
        for arc_id, url, title, visits, typed, last, hidden in arc_urls:
            if url in existing:
                crest_id, crest_visits, crest_typed, crest_last = existing[url]
                url_map[arc_id] = crest_id
                db.execute("UPDATE main.urls SET visit_count = ?, typed_count = ?, last_visit_time = ?, title = CASE WHEN ? > ? THEN ? ELSE title END"
                           " WHERE id = ?", (crest_visits + visits, crest_typed + typed, max(crest_last, last), last, crest_last, title, crest_id))
            else:
                url_map[arc_id] = next_url_id
                new_urls.append((next_url_id, url, title, visits, typed, last, hidden))
                next_url_id += 1
        db.executemany("INSERT INTO main.urls (id, url, title, visit_count, typed_count, last_visit_time, hidden) VALUES (?, ?, ?, ?, ?, ?, ?)",
                       new_urls)

        # Visits in the window, with their chain references renumbered.
        arc_visits = db.execute(
            "SELECT id, url, visit_time, from_visit, transition, visit_duration, incremented_omnibox_typed_score, opener_visit,"
            " consider_for_ntp_most_visited, external_referrer_url, visited_link_id FROM arc.visits WHERE visit_time >= ? ORDER BY id",
            (cutoff,)).fetchall()
        arc_visits = [row for row in arc_visits if row[1] in url_map]
        next_visit_id = (db.execute("SELECT MAX(id) FROM main.visits").fetchone()[0] or 0) + 1
        visit_map = {row[0]: next_visit_id + index for index, row in enumerate(arc_visits)}

        # Visited links: the (link, top-level site, frame) rows the visits point at.
        wanted = {row[10] for row in arc_visits if row[10]}
        link_map, new_links = {}, []
        if wanted:
            db.execute("CREATE TEMP TABLE wanted_links (id INTEGER PRIMARY KEY)")
            db.executemany("INSERT INTO temp.wanted_links VALUES (?)", [(link_id,) for link_id in wanted])
            arc_links = db.execute("SELECT id, link_url_id, top_level_url, frame_url, visit_count FROM arc.visited_links"
                                   " WHERE id IN (SELECT id FROM temp.wanted_links)").fetchall()
            existing_links = {(link, top, frame): (row_id, visits) for row_id, link, top, frame, visits
                              in db.execute("SELECT id, link_url_id, top_level_url, frame_url, visit_count FROM main.visited_links")}
            next_link_id = (db.execute("SELECT MAX(id) FROM main.visited_links").fetchone()[0] or 0) + 1
            for arc_id, link_url, top, frame, visits in arc_links:
                if link_url not in url_map:
                    continue
                key = (url_map[link_url], top, frame)
                if key in existing_links:
                    crest_id, crest_visits = existing_links[key]
                    link_map[arc_id] = crest_id
                    db.execute("UPDATE main.visited_links SET visit_count = ? WHERE id = ?", (crest_visits + visits, crest_id))
                else:
                    link_map[arc_id] = next_link_id
                    existing_links[key] = (next_link_id, visits)
                    new_links.append((next_link_id, *key, visits))
                    next_link_id += 1
            db.executemany("INSERT INTO main.visited_links (id, link_url_id, top_level_url, frame_url, visit_count) VALUES (?, ?, ?, ?, ?)",
                           new_links)
            db.execute("DROP TABLE temp.wanted_links")

        db.executemany(
            "INSERT INTO main.visits (id, url, visit_time, from_visit, transition, segment_id, visit_duration,"
            " incremented_omnibox_typed_score, opener_visit, is_known_to_sync, consider_for_ntp_most_visited, external_referrer_url,"
            " visited_link_id) VALUES (?, ?, ?, ?, ?, 0, ?, ?, ?, 0, ?, ?, ?)",
            [(visit_map[row[0]], url_map[row[1]], row[2], visit_map.get(row[3], 0), row[4], row[5], row[6],
              visit_map.get(row[7], 0), row[8], row[9], link_map.get(row[10], 0)) for row in arc_visits])
        db.execute("COMMIT")
        db.execute("DETACH DATABASE arc")
        return len(new_urls), len(url_map) - len(new_urls), len(arc_visits), len(new_links)


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


def counts(store):
    with sqlite3.connect(f"file:{store}?mode=ro", uri=True) as connection:
        return tuple(connection.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0] for table in ("urls", "visits", "visited_links"))


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--map", action="append", default=[], metavar="ARC=CREST",
                        help="pair an Arc Space with a differently named Crest Space (repeatable)")
    parser.add_argument("--days", type=float, default=90, help="how far back to merge (default 90, Chromium's own retention)")
    parser.add_argument("--dry-run", action="store_true", help="rehearse on copies; Crest keeps running")
    parser.add_argument("--no-relaunch", action="store_true", help="leave Crest closed afterwards")
    args = parser.parse_args()
    sys.stdout.reconfigure(line_buffering=True)
    overrides = dict(item.split("=", 1) for item in args.map if "=" in item)
    cutoff = int((time.time() + CHROMIUM_EPOCH_OFFSET_SECONDS - args.days * 86400) * 1_000_000)

    pairs, unmatched = pair_spaces(overrides)
    for name in unmatched:
        print(f"Skipping Arc Space {name!r}: no Crest Space of that name with a history store (use --map).")
    if not pairs:
        sys.exit("Nothing to move.")

    with tempfile.TemporaryDirectory(prefix="arc-visited-") as scratch:
        scratch = pathlib.Path(scratch)
        if args.dry_run:
            targets = []
            for index, (_, crest_store, _) in enumerate(pairs):
                copy = scratch / f"crest-{index}.sqlite"
                snapshot(crest_store, copy)
                targets.append(copy)
        else:
            quit_crest()
            backup = CACHE / "history-backups" / datetime.datetime.now().strftime("%Y-%m-%d-%H%M%S")
            backup.mkdir(parents=True)
            targets = []
            for index, (_, crest_store, _) in enumerate(pairs):
                shutil.copy2(crest_store, backup / f"{index}-{crest_store.parent.name}-History")
                targets.append(crest_store)
            print(f"Crest's engine history stores are backed up in {backup}")

        for (arc_store, _, label), target in zip(pairs, targets):
            arc_copy = scratch / f"arc-{label.split(' ')[0]}.sqlite"
            snapshot(arc_store, arc_copy)
            before = counts(target)
            added, merged, visits, links = merge(target, arc_copy, cutoff)
            after = counts(target)
            print(f"{label}: {added} addresses added, {merged} merged with Crest's, {visits} visits and {links} visited-link rows added"
                  f" ({before[0]} -> {after[0]} addresses, {before[1]} -> {after[1]} visits, {before[2]} -> {after[2]} visited links)")

    if args.dry_run or args.no_relaunch:
        return
    expected = [counts(store) for _, store, _ in pairs]
    subprocess.run(["open", "-a", "Crest"], check=True)
    time.sleep(20)
    for (_, store, label), before in zip(pairs, expected):
        after = counts(store)
        print(f"{label}: after relaunch {after[0]} addresses, {after[1]} visits, {after[2]} visited links"
              + ("" if after[0] >= before[0] else " (Chromium dropped some)"))


if __name__ == "__main__":
    main()
