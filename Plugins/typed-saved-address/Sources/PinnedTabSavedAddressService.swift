import Foundation
import Observation

/// Keeps a pinned tab at the address it belongs to the way a pinned link
/// would: whenever the tab has no page, because Crest just launched or the
/// page was unloaded, put away or closed, the tab goes back to its saved
/// address, so the page it opens next starts there. A page that is open keeps
/// its place, and the saved address itself changes only when the person edits
/// or replaces it.
@MainActor
@Observable
final class PinnedTabSavedAddressService {
    // MARK: - Static Variables

    static let reopensAtSavedAddressKey = "pinnedTabsReopenAtSavedAddress"

    // MARK: - Variables

    let browser: BrowserStore
    let storage: CrestPluginStorage

    /// Whether pinned tabs without a page return to their saved address. Off,
    /// a pinned tab reopens at the page it showed last, as Crest has it.
    var reopensAtSavedAddress: Bool {
        get { storage.value(Bool.self, forKey: Self.reopensAtSavedAddressKey) ?? true }
        set {
            storage.set(newValue, forKey: Self.reopensAtSavedAddressKey)
            if newValue { returnFreshPinnedTabs() }
        }
    }

    // MARK: - Initializers

    init(browser: BrowserStore, storage: CrestPluginStorage) {
        self.browser = browser
        self.storage = storage
    }

    // MARK: - Actions - Returning

    /// Returns every pinned tab that has no page, in any window, and shows a
    /// page other than its saved one to the address it belongs to. A Space
    /// being deleted, and a tab the core refuses, as in a locked Space, are
    /// left alone.
    func returnFreshPinnedTabs() {
        guard reopensAtSavedAddress else { return }
        let pagedTabIDs = Set(browser.core.state.pages.values.compactMap(\.tabID))
        for space in browser.spaceModels where !browser.isDeleting(space.id) {
            for tab in space.tabs.models
            where tab.placement == .pinned && tab.isAwayFromSavedAddress && !pagedTabIDs.contains(tab.id) {
                _ = browser.returnSessionTabToSavedAddress(tabID: tab.id, in: space.id)
            }
        }
    }
}
