import Foundation

/// A plugin: one personal addition to Crest that the host turns on and off.
/// The type's id matches its `plugin.json`; the generated registry names the
/// type, and the host makes one instance per run.
@MainActor
protocol CrestPlugin: AnyObject {
    static var id: String { get }

    init()

    /// Registers what the plugin contributes and starts anything it runs. A
    /// throw leaves the plugin failed, with the error's description shown in
    /// Settings, and nothing it registered counts.
    func activate(_ context: CrestPluginContext) throws

    /// Stops what `activate` started. The host drops the contributions.
    func deactivate()
}

extension CrestPlugin {
    func deactivate() {}
}

/// What a plugin gets when it is turned on: the stores of both browsing
/// modes, the core, its own storage, the defaults a personal setting may go
/// in, and the place its contributions go.
@MainActor
struct CrestPluginContext {
    let pluginID: String
    let browser: BrowserStore
    let privateBrowser: BrowserStore
    let core: CrestCore
    /// What the plugin keeps between launches, apart from every other
    /// plugin's data; see `CrestPluginStorage`.
    let storage: CrestPluginStorage
    /// Nil in an isolated launch, which keeps no personal settings. Prefer
    /// `storage`: it is scoped to the plugin and survives a named isolated
    /// launch.
    let defaults: UserDefaults?
    let launchEnvironment: BrowserLaunchEnvironment
    let contributions: CrestPluginContributions

    /// Adds `contribution` at `point` under this plugin's name.
    func contribute<Contribution>(_ contribution: Contribution, at point: CrestPluginHookPoint<Contribution>) {
        contributions.register(contribution, at: point, from: pluginID)
    }
}
