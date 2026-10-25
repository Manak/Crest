import SwiftUI

/// A place in the window's chrome where plugins may put a view. Each slot
/// describes itself: its name in the catalog, and whether a view there is
/// drawn for one Space or for the window. The seams stack every active
/// plugin's views for a slot vertically, in catalog order, and draw nothing
/// where no plugin contributes.
struct CrestPluginChromeSlot: Equatable, Hashable, Sendable {
    // MARK: - Static Variables

    /// Under the address field, above the Spaces' moving content. Drawn for
    /// the Space the window shows.
    static let sidebarTop = CrestPluginChromeSlot(name: "sidebarTop", isPerSpace: false)
    /// The top of one Space's content, above its pinned tabs.
    static let spaceAbovePinned = CrestPluginChromeSlot(name: "spaceAbovePinned", isPerSpace: true)
    /// Between one Space's pinned tabs and its header.
    static let spaceBelowPinned = CrestPluginChromeSlot(name: "spaceBelowPinned", isPerSpace: true)
    /// The bottom of one Space's content, under its tab list and above the
    /// Space switcher.
    static let spaceBottom = CrestPluginChromeSlot(name: "spaceBottom", isPerSpace: true)
    /// A bar across the top of a web page, where the translation and
    /// developer bars sit. Drawn with the page.
    static let pageTop = CrestPluginChromeSlot(name: "pageTop", isPerSpace: false)

    static let all: [CrestPluginChromeSlot] = [sidebarTop, spaceAbovePinned, spaceBelowPinned, spaceBottom, pageTop]

    // MARK: - Variables

    let name: String
    let isPerSpace: Bool
}

/// A view a plugin puts in one chrome slot.
struct CrestPluginChromeSlotView: Identifiable {
    // MARK: - Static Variables

    static let hook = CrestPluginHookPoint<CrestPluginChromeSlotView>(id: "chrome.slots", version: 1)

    // MARK: - Variables

    let id: String
    let slot: CrestPluginChromeSlot
    let make: @MainActor (CrestPluginChromeSlotContext) -> CrestPluginView
}

/// What a slot view is drawn for: the window's store, the Space the slot
/// belongs to or the window shows, and the page for a page slot.
struct CrestPluginChromeSlotContext {
    let browser: BrowserStore
    let space: SpaceModel?
    let page: BrowserPage?
}

/// Every active plugin's views for `slot`, stacked. Nothing is drawn, and no
/// space taken, where no plugin contributes to the slot.
struct CrestPluginChromeSlotStack: View {
    let slot: CrestPluginChromeSlot
    let browser: BrowserStore
    var space: SpaceModel? = nil
    var page: BrowserPage? = nil

    @Environment(\.crestPluginHooks) private var hooks

    var body: some View {
        let views = hooks.contributions(at: CrestPluginChromeSlotView.hook).filter { $0.slot == slot }
        if !views.isEmpty {
            VStack(spacing: 0) {
                ForEach(views) { view in
                    view.make(CrestPluginChromeSlotContext(browser: browser, space: space, page: page))
                }
            }
        }
    }
}
