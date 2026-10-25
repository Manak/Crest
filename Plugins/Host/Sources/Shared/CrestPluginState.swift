import Foundation

/// Where a plugin stands in this run of Crest. The fixed states describe
/// themselves: what the settings row says, which symbol it wears, and whether
/// its switch can be moved.
struct CrestPluginState: Equatable, Sendable {
    // MARK: - Static Variables

    static let active = CrestPluginState(
        name: "active", title: "On", symbol: "checkmark.circle.fill", offersToggle: true)
    static let off = CrestPluginState(
        name: "off", title: "Off", symbol: "circle", offersToggle: true)
    /// The switch moved; the plugin follows it when Crest next starts.
    static let relaunchPending = CrestPluginState(
        name: "relaunchPending", title: "After relaunch", symbol: "arrow.clockwise.circle", offersToggle: true)

    // MARK: - Variables

    let name: String
    let title: String
    let symbol: String
    let offersToggle: Bool
    /// Why the plugin is not running, where it cannot be turned on.
    let reason: String?

    // MARK: - Initializers

    private init(name: String, title: String, symbol: String, offersToggle: Bool, reason: String? = nil) {
        self.name = name
        self.title = title
        self.symbol = symbol
        self.offersToggle = offersToggle
        self.reason = reason
    }

    // MARK: - Actions - Unavailable states

    /// The build left the plugin out: a hook it needs did not apply to this
    /// Crest, or its sources did not compile.
    static func unavailable(_ reason: String) -> CrestPluginState {
        CrestPluginState(
            name: "unavailable", title: "Unavailable", symbol: "exclamationmark.triangle.fill", offersToggle: false,
            reason: reason)
    }

    /// The plugin refused to start in this run.
    static func failed(_ reason: String) -> CrestPluginState {
        CrestPluginState(
            name: "failed", title: "Failed", symbol: "xmark.octagon.fill", offersToggle: true, reason: reason)
    }
}
