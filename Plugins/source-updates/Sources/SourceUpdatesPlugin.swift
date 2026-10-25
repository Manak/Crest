import Foundation

/// Software updates for a personal build made from a Git checkout: upstream
/// is fetched and compared, merged into the personal branch, built while
/// Crest keeps running, and installed on relaunch. The update service takes
/// this provider in place of Sparkle's feed when the build knows its checkout.
@MainActor
final class SourceUpdatesPlugin: CrestPlugin {
    // MARK: - Static Variables

    static let id = "source-updates"

    // MARK: - Initializers

    init() {}

    // MARK: - Actions - Lifecycle

    func activate(_ context: CrestPluginContext) throws {
        context.contribute(
            CrestPluginSoftwareUpdateProvider(id: Self.id) { model, preferences in
                // An isolated launch keeps no preferences and never rebuilds.
                guard let preferences, let configuration = BrowserSourceUpdateService.Configuration.current()
                else { return nil }
                return BrowserSourceUpdateService(configuration: configuration, model: model, preferences: preferences)
            },
            at: CrestPluginSoftwareUpdateProvider.hook)
    }
}
