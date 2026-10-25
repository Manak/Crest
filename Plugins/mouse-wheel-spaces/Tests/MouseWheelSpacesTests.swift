import AppKit
import XCTest

@testable import Crest

/// The wheel reading the mouse-wheel-spaces plugin supplies: a free-rolling
/// wheel steps once per flick, and an unturned wheel follows the Mac's scroll
/// direction setting. Crest's own recognizer keeps its phased-gesture tests.
@MainActor
final class MouseWheelSpacesTests: XCTestCase {
    func testPhaseLessWheelStepsOncePerFlickAndForgetsAStaleRemainder() {
        struct Scenario {
            let name: String
            let inputs: [SpaceScrollGestureRecognizer.Input]
            let decisions: [SpaceScrollGestureRecognizer.Decision]
        }

        let scenarios: [Scenario] = [
            Scenario(
                name: "Phase-less stream steps again after its last step ages, and forgets a remainder after a gap",
                inputs: [
                    input(-100, at: 0), input(-100, at: 0.2), input(100, at: 0.6), input(-30, at: 1),
                    input(-30, at: 1.5), input(-10, at: 1.6),
                ],
                decisions: [.step(.next), .consumed, .step(.previous), .consumed, .consumed, .step(.next)]
            ),
            Scenario(
                name: "Wheel notches use their own units, one step per notch, and a quick repeat is the same notch",
                inputs: [
                    input(-1, at: 0, precise: false), input(-10, at: 0.05, precise: false),
                    input(-1, at: 0.4, precise: false), input(1, at: 0.8, precise: false),
                ],
                decisions: [.step(.next), .consumed, .step(.next), .step(.previous)]
            ),
            Scenario(
                name: "Thumb-wheel flicks each step once, through their trailing deltas and an opening blip",
                inputs: [
                    input(-0.1, at: 0, precise: false), input(-0.3, at: 0.02, precise: false),
                    input(-0.8, at: 0.04, precise: false), input(-2, at: 0.06, precise: false),
                    input(-0.1, at: 0.22, precise: false), input(0.3, at: 0.49, precise: false),
                    input(-0.5, at: 0.51, precise: false), input(-1, at: 0.53, precise: false),
                ],
                decisions: [
                    .passThrough, .consumed, .step(.next), .consumed, .consumed, .consumed, .consumed, .step(.next),
                ]
            ),
            Scenario(
                name: "A phased gesture still steps once and stays latched",
                inputs: [
                    input(-100, at: 0, phase: .began), input(-100, at: 0.1, phase: .changed),
                    input(-100, at: 0.2, phase: .changed), input(0, at: 0.3, phase: .ended),
                ],
                decisions: [.step(.next), .consumed, .consumed, .consumed]
            ),
        ]

        for scenario in scenarios {
            XCTContext.runActivity(named: scenario.name) { _ in
                var recognizer = SpaceWheelFlickRecognizer()
                let actual = scenario.inputs.map { recognizer.consume($0, isInside: true) }
                XCTAssertEqual(actual, scenario.decisions)
            }
        }
    }

    func testUnturnedWheelFollowsTheMacScrollDirectionSetting() throws {
        let wheel = try scrollEvent(units: .line, horizontal: -1)
        XCTAssertFalse(wheel.hasPreciseScrollingDeltas)
        XCTAssertFalse(wheel.isDirectionInvertedFromDevice)
        let raw = wheel.scrollingDeltaX
        XCTAssertNotEqual(raw, 0)
        XCTAssertEqual(MouseWheelSpacesPlugin.horizontalDelta(for: wheel, naturalScrolling: false), raw)
        XCTAssertEqual(MouseWheelSpacesPlugin.horizontalDelta(for: wheel, naturalScrolling: true), -raw)

        let precise = try scrollEvent(units: .pixel, horizontal: -40)
        XCTAssertTrue(precise.hasPreciseScrollingDeltas)
        XCTAssertEqual(
            MouseWheelSpacesPlugin.horizontalDelta(for: precise, naturalScrolling: true), precise.scrollingDeltaX)
    }

    private func input(
        _ deltaX: CGFloat, at timestamp: TimeInterval, precise: Bool = true,
        phase: SpaceScrollGestureRecognizer.Phase = .none
    ) -> SpaceScrollGestureRecognizer.Input {
        .init(deltaX: deltaX, deltaY: 0, timestamp: timestamp, isPrecise: precise, phase: phase, isMomentum: false)
    }

    private func scrollEvent(units: CGScrollEventUnit, horizontal: Int32) throws -> NSEvent {
        let event = try XCTUnwrap(
            CGEvent(
                scrollWheelEvent2Source: nil, units: units, wheelCount: 2, wheel1: 0, wheel2: horizontal, wheel3: 0))
        return try XCTUnwrap(NSEvent(cgEvent: event))
    }
}
