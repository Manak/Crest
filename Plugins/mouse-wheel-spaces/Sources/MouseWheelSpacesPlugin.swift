import AppKit

/// Reads a mouse wheel over the Space strip the way the rest of the Mac does:
/// an ordinary wheel the system left unturned follows the scroll direction
/// setting, and a free-rolling thumb wheel steps once per flick.
@MainActor
final class MouseWheelSpacesPlugin: CrestPlugin {
    // MARK: - Static Variables

    static let id = "mouse-wheel-spaces"

    /// The Mac's scroll direction setting: Natural Scrolling, on unless the
    /// person turned it off. It is one setting for every pointing device.
    static var isNaturalScrollingEnabled: Bool {
        UserDefaults.standard.object(forKey: "com.apple.swipescrolldirection") as? Bool ?? true
    }

    // MARK: - Initializers

    init() {}

    // MARK: - Actions - Lifecycle

    func activate(_ context: CrestPluginContext) throws {
        context.contribute(
            CrestPluginSpaceWheel(
                id: Self.id,
                horizontalDelta: { Self.horizontalDelta(for: $0, naturalScrolling: Self.isNaturalScrollingEnabled) },
                makeRecognizer: { SpaceWheelFlickRecognizer() }),
            at: CrestPluginSpaceWheel.hook)
    }

    // MARK: - Actions - Events

    /// The scroll's horizontal delta the way the Mac's scroll direction
    /// setting reads it. AppKit turns a trackpad's deltas around for Natural
    /// Scrolling and says so in `isDirectionInvertedFromDevice`, but an
    /// ordinary wheel's can reach the app the way the device sent them, and
    /// then the Space strip would move against the setting every other
    /// surface follows. A wheel the system left unturned is turned here.
    static func horizontalDelta(for event: NSEvent, naturalScrolling: Bool) -> CGFloat {
        let delta = event.scrollingDeltaX
        guard naturalScrolling, !event.hasPreciseScrollingDeltas, !event.isDirectionInvertedFromDevice
        else { return delta }
        return -delta
    }
}
