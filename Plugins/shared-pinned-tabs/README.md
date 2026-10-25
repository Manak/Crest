# Shared pinned tabs

A pinned tab can be shared into other Spaces. Each Space then has a pinned
copy of it, and every copy opens with the cookies, storage and sign-ins of the
tab's **home Space**: the mail you are signed into at home is the mail you are
signed into from the Work Space's copy. Spaces otherwise keep their cookies
apart as they always did.

## Using it

- Right-click a pinned tab and open **Share in Spaces**. Tick a Space to pin
  a copy there; untick it to remove the copy. **Stop Sharing Everywhere**
  removes every copy.
- Right-click a copy: **Shared from <Space>** jumps to the home tab; **Stop
  Sharing Here** removes this copy.
- Settings → Crest Plugins → Shared pinned tabs lists every shared tab with
  its home and the Spaces it is shared into, each with a Stop Sharing button,
  and the one setting: whether copies **follow the home tab's address, name
  and icon**. On (the default), renaming the home tab, giving it an emoji or
  editing its URL reaches every copy; a change made to a copy is undone at
  the next session change. Off, each copy keeps what it was given when it was
  made.
- A Space's settings page lists the pinned tabs it shares out and the copies
  it holds, with the Space each copy is signed in as.
- Unpinning or deleting the home tab, or deleting its Space, removes every
  copy. Deleting a copy, unpinning it, or deleting its Space ends the share
  for that Space only.

## How it works

Each copy is an ordinary pinned tab of its Space, opened with the home tab's
saved address and title, so it drags, renames and reorders like any pinned
tab and the sidebar needs no change. What differs is where its pages run:
through the host's `core.page-profile` hook the plugin tells the core to open
the copy's pages in the home Space's engine profile (`AssignTabProfile`), and
the core keeps a window or popup those pages open in that profile too, so a
sign-in flow stays signed in. Pages of the copy that other pages open, such
as a link into a new tab, open in the copy's own Space profile as usual.

The plugin keeps its records in its storage, under `shares`: for each shared
tab, the home tab and Space and a `(spaceID, tabID)` per copy; and
`mirrorsFollowHome`, the one setting. At every launch it sends the profile
assignments to the core again. On every session change (`spaces.lifecycle`'s
`sessionChanged`) it reconciles: a share whose home tab is gone or no longer
pinned loses its copies; a copy whose tab is gone or no longer pinned is
forgotten and its assignment taken back; and, when following is on, each copy
takes the home tab's saved address (`AdoptSavedAddress`, the plugin's own core
intent, followed by `ReturnToSavedAddress` so the page goes there), its custom
title and its emoji icon where they differ. `spacesRemoved` drops a home
Space's shares and a member Space's copies.

Turning the plugin off takes every assignment back; the copies stay as plain
pinned tabs of their Spaces and are picked up again when the plugin is turned
on.

## Hooks

`bootstrap` 1, `tabs.edit-actions` 2 (the menu items), `spaces.lifecycle` 1
(reconciling), `plugins.settings` 1 (the settings rows),
`spaces.settings-sections` 1 (the Space page's list), `core.contracts` 1
(`AdoptSavedAddress` and `BrowserTab.AdoptSavedAddress`), `core.page-profile`
1 (the profile assignments).

## Limits

- A copy's pages run in the home profile, so the home Space's extensions,
  site permissions and content blocking apply to them, and a download from a
  copy is attributed to the home Space.
- The pinned grid holds twelve tabs; a Space whose grid is full refuses a
  copy, and the Space stays unticked.
- Private browsing has no shares.
- A copy shows the home Space's sign-in, not a live mirror of the home page:
  the two are separate pages over one profile, as two tabs of one Space are.
