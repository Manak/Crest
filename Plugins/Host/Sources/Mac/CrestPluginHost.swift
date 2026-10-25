import Foundation
import Observation

/// Runs the plugins a build was made with: reads what the build recorded
/// about them, keeps each one's switch and storage, turns the enabled ones on
/// at launch, watches the session for them, and hands their contributions to
/// the seams through `hooks`.
@MainActor
@Observable
final class CrestPluginHost {
    // MARK: - Types

    /// One plugin as Settings shows it: what the build knew, whether its
    /// switch is on, and where it stands in this run.
    struct Record: Identifiable {
        let manifest: CrestPluginsManifest.Plugin
        var isEnabled: Bool
        var state: CrestPluginState

        var id: String { manifest.id }
    }

    // MARK: - Static Variables

    static let enabledKeyPrefix = "crest.plugins.enabled."

    // MARK: - Variables

    let manifest: CrestPluginsManifest?
    let contributions = CrestPluginContributions()
    private(set) var records: [Record] = []

    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private let types: [String: any CrestPlugin.Type]
    @ObservationIgnored private var instances: [String: any CrestPlugin] = [:]
    @ObservationIgnored private var storages: [String: CrestPluginStorage] = [:]
    @ObservationIgnored private var context: CrestPluginContext?
    @ObservationIgnored private var watcher: CrestPluginSpaceWatcher?

    var hooks: CrestPluginHooks { CrestPluginHooks(contributions: contributions) }

    /// The hooks the build could not apply to this Crest, with why.
    var unavailableHooks: [CrestPluginsManifest.Hook] {
        manifest?.hooks.filter { !$0.available } ?? []
    }

    // MARK: - Initializers

    init(
        defaults: UserDefaults?,
        bundle: Bundle = Bundle(for: CrestPluginHost.self),
        types: [any CrestPlugin.Type] = CrestPluginRegistry.plugins
    ) {
        self.defaults = defaults
        self.types = Dictionary(uniqueKeysWithValues: types.map { ($0.id, $0) })
        manifest = CrestPluginsManifest.bundled(in: bundle)
        records = (manifest?.plugins ?? []).map { plugin in
            let isEnabled = defaults?.object(forKey: Self.enabledKey(plugin.id)) as? Bool ?? plugin.enabledByDefault
            // An enabled plugin stays off until `start` turns it on.
            let state: CrestPluginState =
                plugin.available ? .off : .unavailable(plugin.reason ?? "This build left the plugin out.")
            return Record(manifest: plugin, isEnabled: isEnabled, state: state)
        }
    }

    // MARK: - Actions - Launch

    /// Turns the enabled plugins on over the application's stores. Runs once,
    /// before the services that read the hooks are built. A test run hosted
    /// by the app starts none: upstream's tests expect upstream's behavior,
    /// and a plugin's tests build what they test themselves.
    func start(
        browser: BrowserStore, privateBrowser: BrowserStore, core: CrestCore,
        launchEnvironment: BrowserLaunchEnvironment
    ) {
        guard context == nil else { return }
        CrestPluginHooks.installed = hooks
        // The stores every activation shares, kept for the switches moved later.
        let context = CrestPluginContext(
            pluginID: "", browser: browser, privateBrowser: privateBrowser, core: core,
            storage: CrestPluginStorage(pluginID: "", fileURL: nil), defaults: defaults,
            launchEnvironment: launchEnvironment, contributions: contributions)
        self.context = context
        guard !launchEnvironment.isXCTestRuntime else { return }
        for index in records.indices {
            let record = records[index]
            guard record.manifest.available, record.isEnabled else { continue }
            records[index].state = activate(record.manifest, context: context)
        }
        let watcher = CrestPluginSpaceWatcher(browser: browser, contributions: contributions) { [weak self] spaceID in
            self?.forgetSpace(spaceID)
        }
        self.watcher = watcher
        watcher.start()
    }

    // MARK: - Actions - Storage

    /// The storage of `pluginID`, made on first use for this launch. A plugin
    /// that is off keeps its storage; turning it on finds it again.
    func storage(for pluginID: String) -> CrestPluginStorage {
        if let storage = storages[pluginID] { return storage }
        let storage =
            context.map { CrestPluginStorage.forLaunch($0.launchEnvironment, pluginID: pluginID) }
            ?? CrestPluginStorage(pluginID: pluginID, fileURL: nil)
        storages[pluginID] = storage
        return storage
    }

    /// Drops what every plugin stored for a Space that is gone.
    private func forgetSpace(_ spaceID: UUID) {
        for record in records {
            storage(for: record.id).forgetSpace(spaceID)
        }
    }

    // MARK: - Actions - Activation

    private func activate(_ plugin: CrestPluginsManifest.Plugin, context: CrestPluginContext) -> CrestPluginState {
        let context = CrestPluginContext(
            pluginID: plugin.id, browser: context.browser, privateBrowser: context.privateBrowser,
            core: context.core, storage: storage(for: plugin.id), defaults: context.defaults,
            launchEnvironment: context.launchEnvironment, contributions: contributions)
        if let type = types[plugin.id] {
            let instance = type.init()
            do {
                try instance.activate(context)
            } catch {
                contributions.removeAll(from: plugin.id)
                return .failed(error.localizedDescription)
            }
            instances[plugin.id] = instance
        }
        // A patch-only plugin has no type; being on is all it needs.
        contributions.setActive(true, plugin.id)
        return .active
    }

    private func deactivate(_ pluginID: String) {
        contributions.setActive(false, pluginID)
        instances.removeValue(forKey: pluginID)?.deactivate()
        contributions.removeAll(from: pluginID)
    }

    // MARK: - Mutators

    /// Moves a plugin's switch, remembers it, and follows it now where the
    /// plugin allows; a plugin that needs a relaunch waits for one.
    func setEnabled(_ isEnabled: Bool, for pluginID: String) {
        guard let index = records.firstIndex(where: { $0.id == pluginID }) else { return }
        let record = records[index]
        guard record.manifest.available, record.isEnabled != isEnabled else { return }
        defaults?.set(isEnabled, forKey: Self.enabledKey(pluginID))
        records[index].isEnabled = isEnabled
        if record.manifest.requiresRelaunch {
            records[index].state = .relaunchPending
            return
        }
        guard let context else { return }
        if isEnabled {
            records[index].state = activate(record.manifest, context: context)
        } else {
            deactivate(pluginID)
            records[index].state = .off
        }
    }

    private static func enabledKey(_ pluginID: String) -> String {
        enabledKeyPrefix + pluginID
    }
}
