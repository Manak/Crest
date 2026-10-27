import SwiftUI

/// A view a plugin draws over the Space switcher's common-lists button, the
/// control at the page side of the switcher that opens the archive, history
/// and downloads lists. Overlays stack at the button's bottom edge, in
/// catalog order; a plugin whose overlay has nothing to say draws nothing.
struct CrestPluginCommonListsOverlay: Identifiable {
    // MARK: - Static Variables

    static let hook = CrestPluginHookPoint<CrestPluginCommonListsOverlay>(
        id: "switcher.common-lists-overlay", version: 1)

    // MARK: - Variables

    let id: String
    let make: @MainActor (CrestPluginCommonListsContext) -> CrestPluginView
}

/// What the button is drawn from: the list the person chose for it, whether
/// its lists are fanned out, everything the shown Space's profile has
/// downloaded, the finished downloads nobody has looked at, and the Space's
/// accent, which the button's own badge wears.
struct CrestPluginCommonListsContext {
    let chosenSurface: BrowserUtilitySurface
    let isExpanded: Bool
    let downloads: [DownloadState]
    let newDownloads: [DownloadState]
    let badgeColor: Color
}

/// Every active plugin's overlay for the button, stacked. Nothing is drawn
/// where no plugin contributes.
struct CrestPluginCommonListsOverlayStack: View {
    let context: CrestPluginCommonListsContext

    @Environment(\.crestPluginHooks) private var hooks

    var body: some View {
        let overlays = hooks.contributions(at: CrestPluginCommonListsOverlay.hook)
        if !overlays.isEmpty {
            VStack(spacing: 0) {
                ForEach(overlays) { overlay in
                    overlay.make(context)
                }
            }
        }
    }
}
