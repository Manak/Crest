import Foundation

/// Recognizes one horizontal Space intent from scroll input. The Space pager's
/// adapter drives whichever recognizer it holds: Crest's own, or one a plugin
/// supplies for a mouse wheel it reads differently.
protocol SpaceScrollGestureRecognizing {
    mutating func reset()
    mutating func cancelCurrentGesture()
    mutating func consume(
        _ input: SpaceScrollGestureRecognizer.Input, isInside: Bool
    ) -> SpaceScrollGestureRecognizer.Decision
}
