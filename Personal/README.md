# Personal Crest fork

This checkout is a fork of [pauljoda/Crest](https://github.com/pauljoda/Crest)
at [Manak/Crest](https://github.com/Manak/Crest), set up to track upstream
while carrying personal changes. Everything that is specific to this fork
lives in `Personal/`; the rest of the tree stays identical to upstream so
syncing is low friction.

## Layout

| Thing | Value |
| --- | --- |
| `origin` | `git@github.com:Manak/Crest.git` (your fork, push here) |
| `upstream` | `https://github.com/pauljoda/Crest.git` (fetch only; push is disabled) |
| `main` | Exact mirror of `upstream/main`. Never commit here. Tracks `upstream/main`. |
| `mine` | `main` + your commits. Build from this. Tracks `origin/mine`. |
| Installed app | `/Applications/Crest.app`, bundle id `com.manakkapoor.crest` |
| App data | Keyed by the bundle id, e.g. `~/Library/Preferences/com.manakkapoor.crest.plist` and `~/Library/WebKit/com.manakkapoor.crest`. Separate from the official app's data. |

## Plugins

Everything this fork adds to Crest is a plugin under `Plugins/`: the typed
saved address for pinned tabs, the download rows you can drag out as files,
the lists button's menu, the mouse-wheel Space switching, and the in-app
updater itself. `mine` never carries an edited upstream file; the build
patches a small set of hooks in, compiles the plugins beside upstream's code,
and takes the hooks out again. A plugin whose hook no longer applies after an
upstream sync is left out of that build, and Settings → Plugins says why.
Each plugin has its own version and release notes. `Plugins/README.md` has
the whole model; `Plugins/crest-plugins.py status` shows where things stand,
and `status --revision upstream/main` shows what the next sync would break.

## Day to day

The easiest way: **Crest → Settings → About → Check for Updates**. In a
personal build, Software Update works from this checkout instead of the
official Sparkle feed. It fetches upstream, shows how many commits you are
behind with upstream's release notes, and a separate **Chromium engine** line
saying which engine you run, which one upstream now needs, and whether
upstream has published it yet. **Download and Install** merges upstream into
`mine`, builds the app in the background while you keep browsing (the sidebar
card shows each step), and **Install and Relaunch** swaps it in. Two toggles
control automatic checks (hourly, when Crest becomes active) and automatic
builds. Checks run as a child of Crest; the build and the install run as
one-shot launchd agents (`~/Library/Caches/Crest-local-release/jobs/`), because
macOS refuses a GUI app's own children the throwaway binaries Swift Package
Manager compiles for package manifests, and because the install step has to
outlive Crest. Logs: `~/Library/Logs/Crest/source-update.log` (checks and
installs) and `source-update-build.log` (the current build). No Developer
Tools permission is needed.

The same thing from the terminal:

```bash
Personal/sync-upstream.sh && Personal/build-mac.sh
```

`sync-upstream.sh` (run from `mine`) fast-forwards `main`, merges it into
`mine`, and pushes both to your fork. Pass `--rebase` to replay your commits
on top instead (force-pushes `mine` with `--force-with-lease`), or `--no-push`.
A conflicting merge is aborted and reported; resolve it with `git merge main`,
commit, and build again. The in-app updater shows the same error.

`build-mac.sh` applies the plugins first (`Plugins/crest-plugins.py apply`)
and takes them out again when it finishes; `--no-plugins` builds plain
upstream Crest. It then builds the same dual-engine app the official release ships:
it downloads the prebuilt Chromium engine upstream publishes for this
checkout (cached in `~/Library/Caches/Crest-local-release`), publishes the
.NET core, builds the native UI framework, and runs upstream's own packager
(`Scripts/control-plane/package-chromium-host.py`) with your Apple Development
identity (Personal Team `7Y29XS82V8`). It then switches the bundle id to
`com.manakkapoor.crest`, strips the Sparkle update feed so the official
release can never replace your build, re-seals the app, and installs it in
`/Applications`. Pass `--webkit` for the WebKit-only `Crest` scheme (faster,
no engine download) or `--no-install` to get `~/Desktop/Crest.app` instead.
Incremental rebuilds take a few minutes; a clean build is longer because the
.NET core is compiled with NativeAOT and every binary in the engine is re-signed.
`--stage /path/Crest.app` builds without installing and `--install-staged
/path/Crest.app` installs such a build; the in-app updater uses that pair.
Each build regenerates `Crest.xcodeproj` (so the plugin sources under
`Plugins/.build/` are compiled) and restores the tracked project file
afterwards, so the tree stays clean and never conflicts with upstream's
project changes. To work in Xcode, run `Plugins/crest-plugins.py apply --dev`
and `xcodegen generate` yourself, and `Plugins/crest-plugins.py revert`
before committing.

`Personal/bin/codesign` is put first on PATH for the packaging step. It
drops `--timestamp` from upstream's codesign calls: secure timestamps only
matter for notarization, and they fail whenever Apple's timestamp server and
this Mac disagree about the time.

`source-update.py` is what the app calls: `status` prints the comparison as
JSON, `prepare --stage` runs the sync and a staged build, `install --staged`
installs it.

If upstream changes the engine inputs before publishing the matching engine,
the download fails with the engine tag; build with `--webkit` until it appears
under the upstream releases.

Upstream commits the generated `Crest.xcodeproj`, so don't run `xcodegen
generate` unless you changed `project.yml`; a regenerate from a different
XcodeGen version reorders blocks and dirties the tree for no reason.

## Moving Arc's sign-ins over

Crest's own Arc import brings Spaces, tabs and passwords, not cookies, so a
site you were signed in to in Arc asks you to sign in again. Run

```bash
Personal/bin/arc-cookies-to-crest.py --dry-run
```

to see what would move, then the same without `--dry-run`. It pairs each Arc
Space with the Crest Space of the same name (`--map "Arc name=Crest name"`
for others), quits Crest, backs up its cookie stores under
`~/Library/Caches/Crest-local-release/cookie-backups/`, re-encrypts every
unexpired Arc cookie for Crest, and relaunches it. macOS asks for keychain
access twice, for Arc's key and for Crest's. Crest's engine throws session
cookies away at launch, so those are written as persistent cookies that
expire after 30 days (`--session-lifetime-days`). The Swift tool it builds,
`Personal/bin/ArcCookiesToCrest.swift`, is cached beside the engine download.
This personal bundle encrypts with the plain "Chromium Safe Storage" keychain
item, not "Crest Safe Storage": upstream's engine patch only renames it for
`com.pauldavis.crest` bundles.

History does not come over either. `Personal/bin/arc-history-to-crest.py`
(same `--dry-run` and `--map` flags) quits Crest, backs up
`ControlPlane/session.sqlite` under
`~/Library/Caches/Crest-local-release/history-backups/`, and writes each Arc
Space's history into the paired Crest Space's `history.<Space>` checkpoint
part the way Crest's core records it: each address once, without its
fragment, with its first and latest visit, visit count and latest title,
merged with what Crest already has. The core keeps the newest 5000 addresses
per Space, so a long Arc history is cut there (the dry run says which dates
survive). Crest's history, palette and suggestions read the core's store;
Chromium's own `History` database in each profile folder is a second copy the
engine keeps for itself, and it is what colors `:visited` links.
`Personal/bin/arc-visited-links-to-crest.py` (same flags, plus `--days`,
default 90, Chromium's own retention) merges the recent part of Arc's
`History` into it: addresses, visits and `visited_links` rows, renumbered and
folded into what Crest already recorded, with the stores backed up under the
same `history-backups/` folder. Chromium holds these stores exclusively
locked while it runs, so both tools quit Crest first, and the dry runs copy
the files rather than using SQLite's online backup, which would wait on that
lock forever.

The import also leaves every tab with a globe until its page loads, because
it brings titles but not icons. `Personal/bin/arc-icons-to-crest.py` (same
`--dry-run` and `--map` flags) matches each imported tab to its Arc item by
address, then title, and copies Arc's cached icon into Crest's favicon store
for tabs that have none; `--replace` overwrites the ones Crest already has.

`Personal/bin/arc-colors-to-crest.py` (same `--dry-run` and `--map` flags)
gives each Crest Space the colors of the Arc Space of the same name, read the
way Crest's own Arc import reads them, and the accent nearest the first color.
It keeps the Space's banner pattern, strength, texture, crest and icon;
`--arc-look` also sets half strength, no readability fade and text that
follows the system appearance, so the sidebar looks as it did in Arc. It
backs up the session store under `~/Library/Caches/Crest-local-release/color-backups/`.

## Making your own changes

Work on `mine` (or on a feature branch off `mine`, merged back into `mine`).
Commit as usual and `git push`. A change to Crest's behavior is a plugin
under `Plugins/` (see `Plugins/README.md`); fork tooling stays under
`Personal/`. Neither touches an upstream file in the committed tree, so
upstream syncs do not conflict.

If you want to contribute a change back to upstream, branch from `main`, not
`mine`, so the pull request carries only that change:

```bash
git checkout -b fix/thing main
# ... commit ...
git push -u origin fix/thing
gh pr create --repo pauljoda/Crest
```

Upstream has strict contribution rules (`CONTRIBUTING.md`, the
`.agents/skills/crest-contribution` skill, version bump and release-notes
entry per fix). None of that applies to commits that only live on `mine`.

## What differs from the official app

- **Engine.** Same as the official app: Chromium by default with WebKit per
  page, using upstream's published engine build. The whole bundle is signed
  with your identity rather than the author's Developer ID, so it is not
  notarized; Gatekeeper accepts it because it is built locally, not
  downloaded.
- **iCloud sync, push, passkeys.** The upstream entitlements reference the
  author's iCloud container and App ID, which only their team can provision.
  `Personal/Crest-Personal.entitlements` leaves them out, so iCloud sync and
  the passkey browser entitlement are unavailable here. Everything local works.
- **Updates.** No Sparkle feed. Software Update is reimplemented on top of
  this checkout (`BrowserSourceUpdateService`, hooked into
  `BrowserSoftwareUpdateService` only when Info.plist carries
  `CrestSourceCheckout`). The official app's code path is unchanged.
- **Keychain.** Without a `keychain-access-groups` entitlement the app still
  uses the login keychain, but items are scoped to this app's signature.
  Re-signing with a different identity would hide previously saved passwords.

## Requirements already installed

Xcode 27.1, XcodeGen (Homebrew), ripgrep (Homebrew), .NET SDK 10.0.201 in
`~/.dotnet` (via `Scripts/control-plane/install-dotnet.sh`), Python 3.15
(Homebrew), GitHub CLI logged in as `Manak`.
