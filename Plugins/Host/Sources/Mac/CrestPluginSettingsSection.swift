import SwiftUI

/// A section a plugin adds to one of Crest's settings panes, such as General
/// or Tabs. It is rendered after the pane's own sections, inside the same
/// grouped form, so a plugin's rows read like Crest's. The section is made
/// each time the pane draws; keep state in the plugin or its storage.
struct CrestPluginSettingsSection: Identifiable {
    // MARK: - Static Variables

    static let hook = CrestPluginHookPoint<CrestPluginSettingsSection>(id: "settings.sections", version: 1)

    // MARK: - Variables

    let id: String
    /// The pane the section joins, by destination. `.spaces` lands on every
    /// Space's Browsing page after its own sections; `spaces.settings-sections`
    /// is the seam for rows about one Space.
    let destination: BrowserSettingsDestination
    let make: @MainActor () -> CrestPluginView
}

/// Every active plugin's sections for `destination`, in catalog order.
struct CrestPluginSettingsSections: View {
    let destination: BrowserSettingsDestination

    @Environment(\.crestPluginHooks) private var hooks

    var body: some View {
        ForEach(hooks.contributions(at: CrestPluginSettingsSection.hook).filter { $0.destination == destination }) {
            section in
            section.make()
        }
    }
}

/// A section a plugin adds to one Space's settings page, on its Browsing tab
/// between the Space's own rows and its deletion. It is given the Space, so a
/// plugin's per-Space setting is read and written through
/// `storage.space(space.id)`.
struct CrestPluginSpaceSettingsSection: Identifiable {
    // MARK: - Static Variables

    static let hook = CrestPluginHookPoint<CrestPluginSpaceSettingsSection>(
        id: "spaces.settings-sections", version: 1)

    // MARK: - Variables

    let id: String
    let make: @MainActor (CrestPluginSpaceSettingsContext) -> CrestPluginView
}

/// What a Space's settings section is drawn for.
struct CrestPluginSpaceSettingsContext {
    let space: SpaceModel
    let browser: BrowserStore
}

/// Every active plugin's sections for `space`, in catalog order.
struct CrestPluginSpaceSettingsSections: View {
    let space: SpaceModel
    let browser: BrowserStore

    @Environment(\.crestPluginHooks) private var hooks

    var body: some View {
        ForEach(hooks.contributions(at: CrestPluginSpaceSettingsSection.hook)) { section in
            section.make(CrestPluginSpaceSettingsContext(space: space, browser: browser))
        }
    }
}

/// The rows a plugin shows under its own name in Settings → Crest Plugins:
/// its settings, and anything it wants the person to see about what it is
/// doing. Shown while the plugin is on. No upstream seam is needed; the
/// Plugins pane is the host's.
struct CrestPluginSettingsPanel: Identifiable {
    // MARK: - Static Variables

    static let hook = CrestPluginHookPoint<CrestPluginSettingsPanel>(id: "plugins.settings", version: 1)

    // MARK: - Variables

    let id: String
    let make: @MainActor () -> CrestPluginView
}
