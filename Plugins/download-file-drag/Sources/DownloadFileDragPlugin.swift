import SwiftUI

/// Lets a finished download's row in the sidebar be dragged out as its file.
@MainActor
final class DownloadFileDragPlugin: CrestPlugin {
    // MARK: - Static Variables

    static let id = "download-file-drag"

    // MARK: - Initializers

    init() {}

    // MARK: - Actions - Lifecycle

    func activate(_ context: CrestPluginContext) throws {
        context.contribute(
            CrestPluginDownloadRowDecorator(id: Self.id) { row, download in
                AnyView(row.modifier(DownloadFileDragSource(download: download)))
            },
            at: CrestPluginDownloadRowDecorator.hook)
    }
}
