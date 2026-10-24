#!/usr/bin/env python3
"""Move Arc's cookies, and so its sign-ins, into the Crest Spaces of the same name.

Each Arc Space keeps its cookies in the Chromium profile it belongs to, and
each Crest Space owns one Chromium profile folder. This pairs the two by Space
name (``--map`` pairs differently named ones), quits Crest, backs up its cookie
stores, snapshots Arc's, and runs ``ArcCookiesToCrest.swift`` to re-encrypt
every unexpired cookie for Crest. Session cookies become persistent ones with
a bounded lifetime, because Crest's engine discards session cookies at launch.
Crest is relaunched afterwards. Pass ``--dry-run`` to rehearse on copies
without quitting Crest.

macOS asks twice for keychain access: once for Arc's key, once for Crest's.
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
SOURCE = pathlib.Path(__file__).resolve().with_name("ArcCookiesToCrest.swift")
TOOL = CACHE / "tools/ArcCookiesToCrest"

# The personal bundle keeps Chromium's own keychain item; see Personal/README.md.
ARC_KEYCHAIN = ("Arc Safe Storage", "Arc")
CREST_KEYCHAIN = ("Chromium Safe Storage", "Chromium")


def arc_records(value):
    """Arc lists records as an array alternating identities and records, or as an object keyed by identity."""
    if isinstance(value, list):
        return [item for item in value if isinstance(item, dict)]
    if isinstance(value, dict):
        return [item for item in value.values() if isinstance(item, dict)]
    return []


def arc_spaces():
    """Each Arc Space's cookie store, by Space name."""
    sidebar = json.loads((ARC / "StorableSidebar.json").read_text())
    spaces = {}
    for container in sidebar["sidebar"]["containers"]:
        if not isinstance(container, dict):
            continue
        for space in arc_records(container.get("spaces")):
            title = space.get("title")
            profile = space.get("profile") or {}
            if profile.get("default"):
                folder = "Default"
            else:
                folder = ((profile.get("custom") or {}).get("_0") or {}).get("directoryBasename")
            if title and folder and title not in spaces:
                spaces[title] = ARC / "User Data" / folder / "Cookies"
    return spaces


def crest_spaces():
    """Each Crest Space's Chromium cookie store, by Space name."""
    database = CREST / "ControlPlane/session.sqlite"
    with sqlite3.connect(f"file:{database}?mode=ro", uri=True) as connection:
        row = connection.execute("SELECT data FROM checkpoint WHERE part = 'core'").fetchone()
    core = json.loads(row[0])
    return {space["name"]: CREST / "Chromium" / f"Crest-{space['profile']['id']}" / "Cookies" for space in core["spaces"]}


def pair_spaces(overrides):
    """(Arc store, Crest store, name) for every Arc Space with a Crest Space of the same name or a mapped one."""
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


def build_tool():
    if TOOL.exists() and TOOL.stat().st_mtime >= SOURCE.stat().st_mtime:
        return
    TOOL.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(["swiftc", "-O", "-o", str(TOOL), str(SOURCE)], check=True)
    subprocess.run(["codesign", "-s", "-", "-f", str(TOOL)], check=True, capture_output=True)


def snapshot(source, destination):
    """A consistent copy of a cookie store the browser may be writing."""
    with sqlite3.connect(f"file:{source}?mode=ro", uri=True) as origin, sqlite3.connect(destination) as copy:
        origin.backup(copy)


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


def count(store):
    with sqlite3.connect(f"file:{store}?mode=ro", uri=True) as connection:
        return connection.execute("SELECT COUNT(*) FROM cookies").fetchone()[0]


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--map", action="append", default=[], metavar="ARC=CREST",
                        help="pair an Arc Space with a differently named Crest Space (repeatable)")
    parser.add_argument("--session-lifetime-days", type=float, default=30,
                        help="how long Arc's session cookies stay signed in once in Crest (default 30)")
    parser.add_argument("--dry-run", action="store_true", help="rehearse on copies; Crest keeps running")
    parser.add_argument("--no-relaunch", action="store_true", help="leave Crest closed afterwards")
    args = parser.parse_args()
    sys.stdout.reconfigure(line_buffering=True)
    overrides = dict(item.split("=", 1) for item in args.map if "=" in item)

    pairs, unmatched = pair_spaces(overrides)
    for name in unmatched:
        print(f"Skipping Arc Space {name!r}: no Crest Space of that name (use --map).")
    if not pairs:
        sys.exit("Nothing to move.")
    for _, _, label in pairs:
        print(f"Will move {label}")
    build_tool()

    with tempfile.TemporaryDirectory(prefix="arc-cookies-") as scratch:
        scratch = pathlib.Path(scratch)
        if args.dry_run:
            targets = []
            for index, (_, crest_store, _) in enumerate(pairs):
                copy = scratch / f"crest-{index}.sqlite"
                shutil.copy2(crest_store, copy)
                targets.append(copy)
        else:
            quit_crest()
            backup = CACHE / "cookie-backups" / datetime.datetime.now().strftime("%Y-%m-%d-%H%M%S")
            backup.mkdir(parents=True)
            targets = []
            for index, (_, crest_store, label) in enumerate(pairs):
                shutil.copy2(crest_store, backup / f"{index}-{crest_store.parent.name}-Cookies")
                targets.append(crest_store)
            print(f"Crest's cookie stores are backed up in {backup}")

        command = [str(TOOL), "--source-service", ARC_KEYCHAIN[0], "--source-account", ARC_KEYCHAIN[1],
                   "--dest-service", CREST_KEYCHAIN[0], "--dest-account", CREST_KEYCHAIN[1],
                   "--session-lifetime-days", str(args.session_lifetime_days)]
        for index, ((arc_store, _, _), target) in enumerate(zip(pairs, targets)):
            arc_copy = scratch / f"arc-{index}.sqlite"
            snapshot(arc_store, arc_copy)
            command += ["--pair", f"{arc_copy}={target}"]
        if args.dry_run:
            command.append("--dry-run")
        result = subprocess.run(command)
        if result.returncode != 0:
            sys.exit("The move failed; Crest's stores are unchanged (restore from the backup if in doubt).")

    if args.dry_run or args.no_relaunch:
        return
    before = [count(store) for _, store, _ in pairs]
    subprocess.run(["open", "-a", "Crest"], check=True)
    time.sleep(20)
    for (_, store, label), expected in zip(pairs, before):
        kept = count(store)
        print(f"{label}: Crest kept {kept} of {expected} cookies after relaunch" + ("" if kept == expected else " (some were dropped)"))


if __name__ == "__main__":
    main()
