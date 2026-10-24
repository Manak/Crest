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

## Day to day

Pull in upstream changes, then rebuild and reinstall:

```bash
Personal/sync-upstream.sh && Personal/build-mac.sh
```

`sync-upstream.sh` fast-forwards `main`, pushes it to your fork, merges it into
`mine`, and pushes `mine`. Pass `--rebase` if
you prefer your commits replayed on top (it then force-pushes `mine` with
`--force-with-lease`). If a merge conflicts, resolve it, `git commit`, and run
`Personal/build-mac.sh`.

`build-mac.sh` builds the `Crest` scheme in Release, signs it with your Apple
Development identity (Personal Team `7Y29XS82V8`), strips the Sparkle update
feed so the official release can never replace your build, and installs it in
`/Applications`. Pass `--no-install` to get `~/Desktop/Crest.app` instead.
Incremental rebuilds take a few minutes; a clean build is longer because the
.NET core is compiled with NativeAOT.

Upstream commits the generated `Crest.xcodeproj`, so don't run `xcodegen
generate` unless you changed `project.yml`; a regenerate from a different
XcodeGen version reorders blocks and dirties the tree for no reason.

## Making your own changes

Work on `mine` (or on a feature branch off `mine`, merged back into `mine`).
Commit as usual and `git push`. Keep personal files under `Personal/` where
possible so upstream syncs rarely conflict.

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

- **Engine.** This build is WebKit only. The official Mac app packages a
  prebuilt Chromium engine (Chrome extensions, default engine). Upstream
  publishes the matching engine for every checkout as a GitHub release asset
  (`Scripts/control-plane/chromium_engine.py tag` prints the tag), and
  `Scripts/install-local-macos-release.sh` shows the packaging steps, but that
  script is hardwired to the author's Developer ID identity and provisioning
  profile. Adapting it to an Apple Development identity without CloudKit is the
  next step if you want Chromium in your build.
- **iCloud sync, push, passkeys.** The upstream entitlements reference the
  author's iCloud container and App ID, which only their team can provision.
  `Personal/Crest-Personal.entitlements` leaves them out, so iCloud sync and
  the passkey browser entitlement are unavailable here. Everything local works.
- **Updates.** No Sparkle feed. You update by syncing and rebuilding.
- **Keychain.** Without a `keychain-access-groups` entitlement the app still
  uses the login keychain, but items are scoped to this app's signature.
  Re-signing with a different identity would hide previously saved passwords.

## Requirements already installed

Xcode 27.1, XcodeGen (Homebrew), ripgrep (Homebrew), .NET SDK 10.0.201 in
`~/.dotnet` (via `Scripts/control-plane/install-dotnet.sh`), Python 3.15
(Homebrew), GitHub CLI logged in as `Manak`.
