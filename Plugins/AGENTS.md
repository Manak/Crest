# Plugin work: rules for coding agents

These rules apply to every change under `Plugins/`. They sit on top of the
repository's `AGENTS.md` and the `crest-contribution` skill, which still
govern code style, architecture and tests. Read `Plugins/README.md` first.

## Where changes go

- A personal addition to Crest is a plugin, never an edit to an upstream
  file. If no hook exposes the seam you need, add a hook to the host and keep
  the patch generic; the behavior lives in the plugin.
- A patch-only plugin is the last resort, for behavior that cannot be made
  smaller than the seam it would need. Say so in the plugin's summary.
- The committed tree is upstream plus `Personal/` and `Plugins/`. Never commit
  an upstream file with hooks applied; `revert` first. The pre-commit guard
  `apply --dev` installs refuses it.

## Working loop

1. `Plugins/crest-plugins.py apply --dev`, then `xcodegen generate`.
2. Edit plugin sources under `Plugins/<id>/`; for a new or changed hook, edit
   the upstream file in place.
3. `Plugins/crest-plugins.py capture` when a hook's or patch-only plugin's
   files changed; add every changed upstream file to its owner's `files` list
   first.
4. `Plugins/crest-plugins.py doctor` builds the Chromium host and runs the
   core tests. Fix an error in the host or a hook; a plugin that cannot be
   fixed is left out and reported.
5. `Plugins/crest-plugins.py revert`; `git status` shows only `Plugins/` and
   `Personal/`.

## Versions and notes

- A plugin change runs `Plugins/crest-plugins.py bump <id> --category <c>
  --note "<outcome>"` in the same commit. Patch for a fix, `--minor` for a new
  capability, `--major` when the plugin's settings or stored state change
  shape.
- A hook whose contribution shape changes bumps its `version` in `hook.json`
  and `hookCatalogVersion` in `host.json`; plugins that still compile against
  the old shape raise their minimum.
- Plugin-only commits do not run `Scripts/set-version.sh` and do not add to
  `Documentation/ReleaseNotes.json`. `Scripts/check-version.sh --fix-commit`
  is for upstream contributions only.

## Storage, settings and the session

- What a plugin remembers goes in `context.storage` (`CrestPluginStorage`),
  never in `UserDefaults` keys of its own or files it names itself. A value
  about one Space goes in `storage.space(id)`, so it leaves with the Space.
- A plugin with a choice to offer shows it as rows at `plugins.settings`; rows
  about a Space go at `spaces.settings-sections`; a section in another pane
  at `settings.sections`. Rows follow the design system and the writing rules
  of the contribution skill: short native copy, no explanatory subtitles.
- A plugin that reacts to the session registers a `spaces.lifecycle`
  observer. It never polls, never keeps its own copy of the session, and
  changes shared state only through `BrowserStore` methods and core intents.
- State the core must act on, such as a tab's profile, is an intent sent in
  `activate` from storage every launch; see `core.page-profile`.

## Hooks

- A hook's patch opens a seam and nothing more: one line that draws a host
  view or asks the host a question. Behavior lives in the host's contribution
  type or the plugin.
- A hook that needs C# puts it in `Host/Hooks/<id>/Core/`; the patch to the
  upstream file is a `partial` and a call. Never an engine command or event.
- A hook whose seam is in the host's own code (the Plugins pane, the Space
  watcher) is host-only: `files` is empty, and it is listed so plugins can
  name it.
- Changing a hook's contribution shape bumps the hook's `version` and
  `hookCatalogVersion`; adding a type at the same seam keeps old plugins
  compiling, so they keep their minimum.

## Core plugins

- Records are `public`, in namespace `CrestCore.Contracts`, and are intents,
  queries, changes or rejections. No engine commands or events.
- Domain additions are `partial` classes in `Core/`; the type must already be
  partial, which the `core.contracts` hook makes `BrowserTab`. Another type
  is a change to that hook.
- Tests go in `Tests/Core/` as partials of the existing test classes.

## Before handing off

- Both `status` (against the index) and `status --revision upstream/main`
  were run and their results are in the report, including any plugin the next
  sync would leave out.
- `Plugins/README.md` describes every hook the change added or changed, and a
  plugin that is more than a page has a `README.md` saying what it does, how
  it works and what it stores.
- The staged app was launched with `CREST_ISOLATED_SESSION=1`, the plugin's
  behavior checked, Settings → Plugins checked, and the test copy quit,
  unregistered with `lsregister -u` and deleted.
- No build output, state file or copied core source is staged.
