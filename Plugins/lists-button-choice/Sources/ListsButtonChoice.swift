import Foundation

/// The list one Space chose for the sidebar's lists button to open and wear
/// the symbol of. Kept in the plugin's storage under the Space, so each Space
/// has its own and the choice leaves with the Space.
@MainActor
struct ListsButtonChoice {
    // MARK: - Static Variables

    static let pluginID = "lists-button-choice"
    static let surfaceKey = "surface"

    // MARK: - Variables

    let storage: CrestPluginStorage
    /// The Space the choice is about; nil while the window shows none.
    let spaceID: UUID?

    /// The chosen list, or nil where the Space has none and the button opens
    /// the list opened last, as it does without the plugin.
    var surface: BrowserUtilitySurface? {
        guard let spaceID else { return nil }
        return BrowserUtilitySurface.named(storage.space(spaceID).value(String.self, forKey: Self.surfaceKey))
    }

    // MARK: - Mutators

    /// Makes `surface` the Space's list, or nil to leave it without one.
    func choose(_ surface: BrowserUtilitySurface?) {
        guard let spaceID else { return }
        storage.space(spaceID).set(surface?.name, forKey: Self.surfaceKey)
    }
}
