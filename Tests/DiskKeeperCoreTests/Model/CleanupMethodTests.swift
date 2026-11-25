import XCTest
@testable import DiskKeeperCore

final class CleanupMethodTests: XCTestCase {
    private let all: [CleanupMethod] = [
        .trash,
        .trashWorktree(mainRepoPath: "/Users/me/code/app"),
        .toolCommand(command: "ollama", arguments: ["rm", "llama3:8b"]),
        .toolCommand(command: "x", arguments: []),
        .none,
    ]

    func testRoundTripAllCases() throws {
        for m in all { XCTAssertEqual(try roundTrip(m), m) }
    }

    func testPinnedJSONShapes() throws {
        XCTAssertEqual(try jsonString(CleanupMethod.trash), #"{"kind":"trash"}"#)
        XCTAssertEqual(try jsonString(CleanupMethod.trashWorktree(mainRepoPath: "/Users/me/code/app")),
                       #"{"kind":"trashWorktree","mainRepoPath":"\/Users\/me\/code\/app"}"#)
        XCTAssertEqual(try jsonString(CleanupMethod.toolCommand(command: "ollama", arguments: ["rm", "llama3:8b"])),
                       #"{"arguments":["rm","llama3:8b"],"command":"ollama","kind":"toolCommand"}"#)
        XCTAssertEqual(try jsonString(CleanupMethod.none), #"{"kind":"none"}"#)
    }

    func testUnknownKindThrows() {
        XCTAssertThrowsError(try decodeJSON(CleanupMethod.self, #"{"kind":"shred"}"#))
    }

    func testIsActionable() {
        for m in all { XCTAssertEqual(m.isActionable, m != .none) }
    }
}
