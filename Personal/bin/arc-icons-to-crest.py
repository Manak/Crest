#!/usr/bin/env python3
"""Give the tabs Crest imported from Arc the icons Arc showed for them.

Crest's Arc import brings each tab's address and title but not its icon, so an
imported tab shows a globe until its page loads. Arc keeps every sidebar
item's icon in ``SidebarItemsFaviconCache`` under the MD5 of the item's ID, and
Crest keeps each open tab's icon in ``Favicons/<tab ID>.favicon``, which it
reads at launch for any tab that has none. This pairs Spaces by name
(``--map`` for differently named ones), matches each Crest tab to an Arc item
by address and then by title, quits Crest, copies the icons across for tabs
that have none (``--replace`` for all), and relaunches Crest. Once a page loads
in Crest, its live icon takes over as usual.
"""

import argparse
import hashlib
import json
import pathlib
import shutil
import sqlite3
import subprocess
import sys
import time

HOME = pathlib.Path.home()
ARC = HOME / "Library/Application Support/Arc"
CREST = HOME / "Library/Application Support/Crest"
FAVICONS = CREST / "Favicons"
# BrowserFaviconCapture.maximumByteCount: the store ignores anything larger.
MAXIMUM_ICON_BYTES = 128 * 1024


def arc_records(value):
    """Arc lists records as an array alternating identities and records, or as an object keyed by identity."""
    if isinstance(value, list):
        return [item for item in value if isinstance(item, dict)]
    if isinstance(value, dict):
        return [item for item in value.values() if isinstance(item, dict)]
    return []


def arc_profile_key(profile):
    if not isinstance(profile, dict):
        return "unknown"
    if profile.get("default"):
        return "default"
    custom = (profile.get("custom") or {}).get("_0") or {}
    return f"custom:{custom.get('machineID', '')}:{custom.get('directoryBasename', '')}"


def arc_spaces():
    """Each Arc Space's tabs, favorites included, as (item ID, address, title), by Space name."""
    sidebar = json.loads((ARC / "StorableSidebar.json").read_text())
    spaces = {}
    for container in sidebar["sidebar"]["containers"]:
        if not isinstance(container, dict):
            continue
        items = {record["id"]: record for record in arc_records(container.get("items")) if record.get("id")}
        favorites = container.get("topAppsContainerIDs") or []
        favorite_roots = {arc_profile_key(favorites[index]): favorites[index + 1]
                          for index in range(0, len(favorites) - 1, 2) if isinstance(favorites[index + 1], str)}
        for space in arc_records(container.get("spaces")):
            title = space.get("title")
            if not title or title in spaces:
                continue
            tabs = []
            seen = set()

            def walk(item_id, depth=0):
                record = items.get(item_id)
                if record is None or depth > 16 or item_id in seen:
                    return
                seen.add(item_id)
                tab = (record.get("data") or {}).get("tab") or {}
                if tab.get("savedURL"):
                    tabs.append((item_id, tab["savedURL"], tab.get("savedTitle") or record.get("title") or ""))
                for child in record.get("childrenIds") or []:
                    walk(child, depth + 1)

            root = favorite_roots.get(arc_profile_key(space.get("profile")))
            if root:
                walk(root)
            for section in space.get("containerIDs") or space.get("newContainerIDs") or []:
                if section not in ("pinned", "unpinned"):
                    walk(section)
            spaces[title] = tabs
    return spaces


def crest_spaces():
    """Each Crest Space's open tabs as (tab ID, address, title), by Space name."""
    database = CREST / "ControlPlane/session.sqlite"
    with sqlite3.connect(f"file:{database}?mode=ro", uri=True) as connection:
        row = connection.execute("SELECT data FROM checkpoint WHERE part = 'core'").fetchone()
    core = json.loads(row[0])
    spaces = {}
    for space in core["spaces"]:
        tabs = []
        for tab in space["tabs"]:
            identity = tab["id"]["rawValue"] if isinstance(tab["id"], dict) else tab["id"]
            tabs.append((identity, tab.get("url") or tab.get("savedURL") or "", tab.get("title") or ""))
        spaces[space["name"]] = tabs
    return spaces


def arc_icon(item_id):
    path = ARC / "SidebarItemsFaviconCache" / hashlib.md5(item_id.encode()).hexdigest()
    if path.is_file() and 0 < path.stat().st_size <= MAXIMUM_ICON_BYTES and path.read_bytes()[:8] == b"\x89PNG\r\n\x1a\n":
        return path
    return None


def plan(overrides, replace):
    """(Arc icon, Crest icon file, label) for every Crest tab that gets an icon, plus what was left out."""
    arc = arc_spaces()
    crest = crest_spaces()
    folded = {name.casefold(): name for name in arc}
    copies, notes = [], []
    for crest_name, tabs in crest.items():
        arc_name = next((key for key, value in overrides.items() if value == crest_name), None) \
            or folded.get(crest_name.casefold())
        if arc_name not in arc:
            continue
        by_url, by_title = {}, {}
        for item_id, url, title in arc[arc_name]:
            by_url.setdefault(url, item_id)
            if title:
                by_title.setdefault(title, item_id)
        for tab_id, url, title in tabs:
            if not url:
                continue
            target = FAVICONS / f"{tab_id}.favicon"
            if target.exists() and not replace:
                continue
            item_id = by_url.get(url) or by_title.get(title)
            icon = arc_icon(item_id) if item_id else None
            if icon is None:
                notes.append(f"{crest_name}: no Arc icon for {title or url!r}")
                continue
            copies.append((icon, target, f"{crest_name}: {title or url}"))
    return copies, notes


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


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--map", action="append", default=[], metavar="ARC=CREST",
                        help="pair an Arc Space with a differently named Crest Space (repeatable)")
    parser.add_argument("--replace", action="store_true", help="also replace icons Crest already has")
    parser.add_argument("--dry-run", action="store_true", help="list what would be copied; Crest keeps running")
    parser.add_argument("--no-relaunch", action="store_true", help="leave Crest closed afterwards")
    args = parser.parse_args()
    sys.stdout.reconfigure(line_buffering=True)
    overrides = dict(item.split("=", 1) for item in args.map if "=" in item)

    copies, notes = plan(overrides, args.replace)
    for note in notes:
        print(note)
    if not copies:
        sys.exit("Nothing to copy.")
    for _, _, label in copies:
        print(("Would copy " if args.dry_run else "Copying ") + label)
    if args.dry_run:
        return

    quit_crest()
    FAVICONS.mkdir(parents=True, exist_ok=True)
    for icon, target, _ in copies:
        shutil.copyfile(icon, target)
    print(f"Copied {len(copies)} icon(s).")
    if not args.no_relaunch:
        subprocess.run(["open", "-a", "Crest"], check=True)


if __name__ == "__main__":
    main()
