import Foundation

/// Draws a small progress bar along the bottom of the Space switcher's lists
/// button while a download runs, so the person sees it moving without opening
/// Downloads. The bar is there only while the button is set to open Downloads
/// and tracks the first download that was started and is still running; the
/// others show in the list.
@MainActor
final class DownloadsProgressPlugin: CrestPlugin {
    // MARK: - Static Variables

    static let id = "downloads-progress"

    // MARK: - Initializers

    init() {}

    // MARK: - Actions - Lifecycle

    func activate(_ context: CrestPluginContext) throws {
        context.contribute(
            CrestPluginCommonListsOverlay(id: Self.id) { context in
                CrestPluginView(DownloadsProgressBar(context: context))
            },
            at: CrestPluginCommonListsOverlay.hook)
    }
}
