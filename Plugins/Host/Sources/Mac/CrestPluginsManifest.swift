import Foundation

/// What the build recorded about the plugins it was made with, bundled as
/// `CrestPlugins.json` by `Plugins/crest-plugins.py apply`.
struct CrestPluginsManifest: Decodable, Sendable {
    // MARK: - Types

    struct Hook: Decodable, Identifiable, Sendable {
        let id: String
        let version: Int
        let available: Bool
        let reason: String?
    }

    struct Plugin: Decodable, Identifiable, Sendable {
        let id: String
        let name: String
        let version: String
        let summary: String
        /// "hook", "core" or "patch": how the plugin reaches Crest.
        let tier: String
        let requiresRelaunch: Bool
        let enabledByDefault: Bool
        let hooks: [String: Int]
        /// Whether the build compiled the plugin in; false names a reason.
        let available: Bool
        let reason: String?
    }

    // MARK: - Static Variables

    static let resourceName = "CrestPlugins"

    // MARK: - Variables

    let hostVersion: String
    let hookCatalogVersion: Int
    let crestVersion: String
    let hooks: [Hook]
    let plugins: [Plugin]

    // MARK: - Actions - Loading

    /// The manifest bundled beside the host's code, or nil for a build made
    /// without the plugin system.
    static func bundled(in bundle: Bundle) -> CrestPluginsManifest? {
        guard let url = bundle.url(forResource: resourceName, withExtension: "json"),
            let data = try? Data(contentsOf: url)
        else { return nil }
        return try? JSONDecoder().decode(CrestPluginsManifest.self, from: data)
    }
}
