import Foundation

/// Where a build's software updates come from in place of Sparkle's feed. A
/// plugin supplies one for a build that updates another way, and the update
/// service hands it the checks, the preferences and the settings section.
@MainActor
protocol BrowserSoftwareUpdateProviding: AnyObject {
    var automaticallyChecksForUpdates: Bool { get }
    var automaticallyDownloadsUpdates: Bool { get }
    /// The rows shown in place of the feed's in About.
    var settingsSection: CrestPluginView { get }

    func start()
    func checkForUpdates()
    func applicationDidBecomeActive()
    func setAutomaticallyChecksForUpdates(_ isEnabled: Bool)
    func setAutomaticallyDownloadsUpdates(_ isEnabled: Bool)
}

/// A plugin's offer to provide software updates, taken up when the update
/// service starts. `make` answers nil for a build the provider cannot serve,
/// which leaves the feed in place.
struct CrestPluginSoftwareUpdateProvider: Identifiable {
    // MARK: - Static Variables

    static let hook = CrestPluginHookPoint<CrestPluginSoftwareUpdateProvider>(
        id: "software-updates.provider", version: 1)

    // MARK: - Variables

    let id: String
    let make: @MainActor (BrowserSoftwareUpdateModel, UserDefaults?) -> (any BrowserSoftwareUpdateProviding)?
}
