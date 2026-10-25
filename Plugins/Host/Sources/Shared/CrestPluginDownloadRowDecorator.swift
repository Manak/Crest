import SwiftUI

/// Dresses a download's row in the sidebar lists: a plugin wraps the row in a
/// modifier of its own, such as a drag source for the finished file.
struct CrestPluginDownloadRowDecorator: Identifiable {
    // MARK: - Static Variables

    static let hook = CrestPluginHookPoint<CrestPluginDownloadRowDecorator>(
        id: "downloads.row-decoration", version: 1)

    // MARK: - Variables

    let id: String
    /// The row, wrapped. The host erases the row's type here and nowhere
    /// else: a plugin cannot name a view type the host has not seen.
    let decorate: @MainActor (AnyView, DownloadState) -> AnyView
}

/// Applies every active plugin's decoration to a download row.
struct CrestPluginDownloadRowDecoration: ViewModifier {
    let download: DownloadState

    @Environment(\.crestPluginHooks) private var hooks

    func body(content: Content) -> some View {
        hooks.contributions(at: CrestPluginDownloadRowDecorator.hook)
            .reduce(AnyView(content)) { decorated, decorator in decorator.decorate(decorated, download) }
    }
}
