# Typed saved address

A saved or pinned tab belongs to an address. This plugin lets that address be
typed, and makes a pinned tab keep it the way a pinned link would.

## Using it

- Right-click a saved or pinned tab, open **Edit Tab** and choose **Edit
  URL…**. Type the address the tab belongs to and Save; the tab goes there as
  returning to a saved address does. Crest's own **Replace with Current URL**
  still works, and nothing else changes the saved address.
- A pinned tab reopens at its saved address: at launch, and after its page was
  unloaded, put away or closed, the next page it opens starts at the saved
  address rather than at the page it showed last. A pinned tab whose page is
  open keeps its place until then.
- Settings → Crest Plugins → Typed saved address has the one setting, **Pinned
  tabs reopen at their saved URL**. Off, pinned tabs reopen at the page they
  showed last, as Crest has it.

## How it works

Edit URL… sends `SetSavedAddress`, the plugin's own core intent: the input is
resolved by the Space's address rules as an address typed into the palette
is, and becomes the tab's saved address while the page stays where it is;
the menu's return action then takes the page there.

The pinned-tab return is Swift only. At launch, before any page opens, and
on every `spaces.lifecycle` report of a session or page change, the plugin
sends `ReturnToSavedAddress` for each pinned tab that has no page in any
window and shows a page other than its saved one. The core then records the
saved address as the tab's address, so the page the tab opens next loads it,
and the state kept for the page it showed last no longer matches and is
dropped. The saved address itself is never changed by the plugin; only Edit
URL… and Replace with Current URL change it.

The plugin stores one value, `pinnedTabsReopenAtSavedAddress`, in its storage.

## Hooks

`bootstrap` 1, `tabs.edit-actions` 1 (the menu action), `spaces.lifecycle` 2
(the session and page reports), `plugins.settings` 1 (the settings row),
`core.contracts` 1 (`SetSavedAddress` and `BrowserTab.SetSavedAddress`).

## Limits

- Only pinned tabs return; a saved tab in a folder reopens where Crest leaves
  it, and Crest's own "After closing" setting still decides what closing a
  saved or pinned tab does.
- A pinned tab in a locked Space returns once the Space is unlocked and its
  session or pages next change.
