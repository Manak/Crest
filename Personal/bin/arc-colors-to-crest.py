#!/usr/bin/env python3
"""Give each Crest Space the colors of the Arc Space of the same name.

Arc keeps a Space's theme in ``StorableSidebar.json``: the base colors of its
gradient, or its single color. Crest keeps a Space's colors in its branding in
the ``core`` part of its session checkpoint. This reads Arc's colors the way
Crest's own Arc import does (gradient base colors, else the single color, else
the palette's mid tone, at most three), pairs Spaces by name (``--map`` pairs
differently named ones), quits Crest, backs up its session store, and replaces
only each Space's colors and accent. The banner pattern, texture, crest and
icon a Space already has stay as they are; ``--arc-look`` also paints the
colors at half strength with no readability fade and text that follows the
system appearance, so the sidebar looks as it did in Arc. Crest is relaunched afterwards.
Pass ``--dry-run`` to see what would change without quitting Crest.
"""

import argparse
import datetime
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
CACHE = HOME / "Library/Caches/Crest-local-release"
SESSION = CREST / "ControlPlane/session.sqlite"

# SpaceBranding.MaximumColorCount.
MAXIMUM_COLORS = 3
# Arc draws its dark base colors translucent over the window, so in light mode
# a Space shows near its palette's mid tone; half strength over Crest's window
# lands there.
ARC_STRENGTH = 0.5
# Each SpaceAccent's swatch (Tincture), in SpaceAccent.All order.
ACCENTS = [("indigo", (0.29, 0.25, 0.58)), ("orange", (0.85, 0.27, 0.20)),
           ("teal", (0.12, 0.49, 0.52)), ("rose", (0.72, 0.25, 0.42))]


def arc_records(value):
    """Arc lists records as an array alternating identities and records, or as an object keyed by identity."""
    if isinstance(value, list):
        return [item for item in value if isinstance(item, dict)]
    if isinstance(value, dict):
        return [item for item in value.values() if isinstance(item, dict)]
    return []


def path(value, *keys):
    for key in keys:
        value = value.get(key) if isinstance(value, dict) else None
    return value


def color(value):
    if not isinstance(value, dict) or not all(isinstance(value.get(key), (int, float)) for key in ("red", "green", "blue")):
        return None
    unit = lambda number: min(max(float(number), 0.0), 1.0)
    return {"red": unit(value["red"]), "green": unit(value["green"]), "blue": unit(value["blue"]),
            "alpha": unit(value.get("alpha", 1))}


def arc_colors(theme):
    """ArcSidebar.Colors: the gradient's base colors, else the single color, else the palette's mid tone."""
    style = path(theme, "background", "single", "_0", "style", "color", "_0")
    colors = [c for c in map(color, path(style, "blendedGradient", "_0", "baseColors") or []) if c]
    if not colors and (single := color(path(style, "blendedSingleColor", "_0", "color"))):
        colors.append(single)
    if not colors and (mid_tone := color(path(theme, "primaryColorPalette", "midTone"))):
        colors.append(mid_tone)
    return colors[:MAXIMUM_COLORS]


def arc_spaces():
    """Each Arc Space's colors, by Space name."""
    sidebar = json.loads((ARC / "StorableSidebar.json").read_text())
    spaces = {}
    for container in sidebar["sidebar"]["containers"]:
        if not isinstance(container, dict):
            continue
        for space in arc_records(container.get("spaces")):
            title = space.get("title")
            colors = arc_colors(path(space, "customInfo", "windowTheme"))
            if title and colors and title not in spaces:
                spaces[title] = colors
    return spaces


def nearest_accent(first):
    """SpaceAccent.Nearest: the accent whose swatch lies nearest in red, green and blue."""
    rgb = (first["red"], first["green"], first["blue"])
    return min(ACCENTS, key=lambda accent: sum((a - b) ** 2 for a, b in zip(rgb, accent[1])))[0]


def describe(colors):
    return " ".join("#{:02x}{:02x}{:02x}".format(*(round(c[key] * 255) for key in ("red", "green", "blue")))
                    for c in colors)


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


def read_core():
    with sqlite3.connect(f"file:{SESSION}?mode=ro", uri=True) as connection:
        row = connection.execute("SELECT data FROM checkpoint WHERE part = 'core'").fetchone()
    return json.loads(bytes(row[0]))


def apply(core, arc, overrides, arc_look):
    """Set each paired Crest Space's colors and accent in place; returns what changed and the unmatched Arc Spaces."""
    folded = {space["name"].casefold(): space for space in core["spaces"]}
    by_name = {space["name"]: space for space in core["spaces"]}
    changes, unmatched = [], []
    for name, colors in arc.items():
        space = by_name.get(overrides.get(name, "")) or folded.get(name.casefold())
        if space is None:
            unmatched.append(name)
            continue
        branding = space.setdefault("branding", {})
        before = describe(branding.get("colors") or [])
        branding["colors"] = colors
        space["accent"] = nearest_accent(colors[0])
        if arc_look:
            branding["bannerStrength"] = ARC_STRENGTH
            branding["readabilityFade"] = 0
            branding["textColorMode"] = "system"
        changes.append(f"{name} -> {space['name']}: {before or 'none'} => {describe(colors)} (accent {space['accent']})"
                       + (f", {ARC_STRENGTH:.0%} strength, no fade, system text" if arc_look else ""))
    return changes, unmatched


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--map", action="append", default=[], metavar="ARC=CREST",
                        help="pair an Arc Space with a differently named Crest Space (repeatable)")
    parser.add_argument("--arc-look", action="store_true",
                        help="also paint the colors translucent, with no readability fade and system text, as Arc does")
    parser.add_argument("--dry-run", action="store_true", help="report what would change; Crest keeps running")
    parser.add_argument("--no-relaunch", action="store_true", help="leave Crest closed afterwards")
    args = parser.parse_args()
    sys.stdout.reconfigure(line_buffering=True)
    overrides = dict(item.split("=", 1) for item in args.map if "=" in item)

    arc = arc_spaces()
    changes, unmatched = apply(read_core(), arc, overrides, args.arc_look)
    for name in unmatched:
        print(f"Skipping Arc Space {name!r}: no Crest Space of that name (use --map).")
    if not changes:
        sys.exit("Nothing to change.")
    for change in changes:
        print(("Would set " if args.dry_run else "Setting ") + change)
    if args.dry_run:
        return

    quit_crest()
    backup = CACHE / "color-backups" / datetime.datetime.now().strftime("%Y-%m-%d-%H%M%S")
    backup.mkdir(parents=True)
    for suffix in ("", "-wal", "-shm"):
        source = SESSION.with_name(SESSION.name + suffix)
        if source.exists():
            shutil.copy2(source, backup / source.name)
    print(f"Crest's session store is backed up in {backup}")

    # Read again now that Crest has quit and written its last checkpoint.
    core = read_core()
    apply(core, arc, overrides, args.arc_look)
    with sqlite3.connect(SESSION) as connection:
        # Crest reads the part as System.Text.Json wrote it: compact JSON.
        data = json.dumps(core, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        connection.execute("UPDATE checkpoint SET data = ? WHERE part = 'core'", (data,))
        connection.commit()
    print(f"Updated {len(changes)} Space(s).")

    if not args.no_relaunch:
        subprocess.run(["open", "-a", "Crest"], check=True)


if __name__ == "__main__":
    main()
