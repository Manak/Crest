import AppKit
import SwiftUI

/// Keeps AppKit phase, delta conventions, and event consumption at the native boundary.
@MainActor
final class SpaceScrollGestureEventAdapter {
    // MARK: - Static Variables

    /// The Mac's scroll direction setting: Natural Scrolling, on unless the
    /// person turned it off. It is one setting for every pointing device.
    static var isNaturalScrollingEnabled: Bool {
        UserDefaults.standard.object(forKey: "com.apple.swipescrolldirection") as? Bool ?? true
    }

    // MARK: - Variables

    private var recognizer = SpaceScrollGestureRecognizer()

    // MARK: - Actions - Recognition

    func reset() {
        recognizer.reset()
    }

    func cancelCurrentGesture() {
        recognizer.cancelCurrentGesture()
    }

    func handle(
        _ event: NSEvent, isInside: Bool, layoutDirection: LayoutDirection,
        isEnabled: Bool = true,
        onStep: (BrowserSpaceSwipeDirection) -> Void
    ) -> NSEvent? {
        if !isEnabled { recognizer.cancelCurrentGesture() }
        let decision = recognizer.consume(
            Self.input(
                for: event, layoutDirection: layoutDirection, naturalScrolling: Self.isNaturalScrollingEnabled),
            isInside: isInside && isEnabled)
        guard isEnabled else { return event }
        if let direction = decision.direction { onStep(direction) }
        return decision.consumesEvent ? nil : event
    }

    // MARK: - Actions - Events

    static func input(
        for event: NSEvent, layoutDirection: LayoutDirection, naturalScrolling: Bool
    ) -> SpaceScrollGestureRecognizer.Input {
        let phase: SpaceScrollGestureRecognizer.Phase
        if event.phase.contains(.cancelled) {
            phase = .cancelled
        } else if event.phase.contains(.ended) {
            phase = .ended
        } else if event.phase.contains(.began) {
            phase = .began
        } else if event.phase.contains(.mayBegin) {
            phase = .mayBegin
        } else if !event.phase.isEmpty {
            phase = .changed
        } else {
            phase = .none
        }
        return .init(
            deltaX: layoutDirection.semanticHorizontalTranslation(
                horizontalDelta(for: event, naturalScrolling: naturalScrolling)),
            deltaY: event.scrollingDeltaY,
            timestamp: event.timestamp,
            isPrecise: event.hasPreciseScrollingDeltas,
            phase: phase,
            isMomentum: !event.momentumPhase.isEmpty
        )
    }

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
