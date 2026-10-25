import Foundation
import XCTest

@testable import Crest

/// The contract a plugin's storage keeps silently: a value comes back as it
/// went in across a relaunch, one plugin's document never sees another's, a
/// Space's values leave with the Space, and a value whose shape changed reads
/// as absent rather than as something else.
@MainActor
final class CrestPluginStorageTests: XCTestCase {
    private struct Share: Codable, Equatable {
        let home: UUID
        var members: [UUID]
    }

    private var root: URL!

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "crest-plugin-storage-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    func testValuesSurviveARelaunchAndStayWithinTheirPluginAndSpace() {
        let share = Share(home: UUID(), members: [UUID(), UUID()])
        let space = UUID()
        let other = UUID()

        let first = CrestPluginStorage(pluginID: "one", fileURL: root.appendingPathComponent("one"))
        first.set(share, forKey: "share")
        first.set(true, forKey: "follows")
        first.space(space).set("muted", forKey: "mode")
        first.space(other).set("loud", forKey: "mode")
        XCTAssertEqual(first.value(Share.self, forKey: "share"), share)
        XCTAssertEqual(first.keys, ["follows", "share"])
        XCTAssertEqual(Set(first.spaceIDs), [space, other])

        // Another plugin's document is its own.
        let neighbour = CrestPluginStorage(pluginID: "two", fileURL: root.appendingPathComponent("two"))
        XCTAssertNil(neighbour.value(Share.self, forKey: "share"))
        XCTAssertTrue(neighbour.isEmpty)

        // A relaunch reads what was written, plugin-wide and per Space.
        let relaunched = CrestPluginStorage(pluginID: "one", fileURL: root.appendingPathComponent("one"))
        XCTAssertEqual(relaunched.value(Share.self, forKey: "share"), share)
        XCTAssertEqual(relaunched.value(Bool.self, forKey: "follows"), true)
        XCTAssertEqual(relaunched.space(space).value(String.self, forKey: "mode"), "muted")
        XCTAssertEqual(relaunched.space(other).value(String.self, forKey: "mode"), "loud")

        // A value that no longer decodes as the type asked for is absent, not wrong.
        XCTAssertNil(relaunched.value(Int.self, forKey: "share"))

        // A Space's values leave with the Space; the others stay.
        relaunched.forgetSpace(space)
        XCTAssertNil(relaunched.space(space).value(String.self, forKey: "mode"))
        XCTAssertEqual(relaunched.space(other).value(String.self, forKey: "mode"), "loud")
        XCTAssertEqual(relaunched.spaceIDs, [other])

        // Removing a key and the whole document reach disk too.
        relaunched.removeValue(forKey: "follows")
        relaunched.removeAll()
        let emptied = CrestPluginStorage(pluginID: "one", fileURL: root.appendingPathComponent("one"))
        XCTAssertTrue(emptied.isEmpty)
    }

    func testAnInMemoryStorageKeepsValuesForTheLaunchOnly() {
        let storage = CrestPluginStorage(pluginID: "one", fileURL: nil)
        storage.set(3, forKey: "count")
        XCTAssertEqual(storage.value(Int.self, forKey: "count"), 3)
        XCTAssertFalse(storage.isPersistent)
        XCTAssertNil(CrestPluginStorage(pluginID: "one", fileURL: nil).value(Int.self, forKey: "count"))
    }
}
