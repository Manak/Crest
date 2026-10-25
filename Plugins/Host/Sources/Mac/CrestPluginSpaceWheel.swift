import AppKit

/// How a plugin reads a mouse wheel over the Space strip: the horizontal
/// delta it takes from each AppKit event, and the recognizer that turns the
/// deltas into Space steps. One plugin supplies both, so the adapter follows
/// one reading of the wheel.
struct CrestPluginSpaceWheel: Identifiable {
    // MARK: - Static Variables

    static let hook = CrestPluginHookPoint<CrestPluginSpaceWheel>(id: "space-pager.wheel", version: 1)

    // MARK: - Variables

    let id: String
    let horizontalDelta: @MainActor (NSEvent) -> CGFloat
    let makeRecognizer: @MainActor () -> any SpaceScrollGestureRecognizing
}
