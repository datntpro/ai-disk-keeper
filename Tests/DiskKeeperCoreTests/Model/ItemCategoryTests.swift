import XCTest
@testable import DiskKeeperCore

final class ItemCategoryTests: XCTestCase {
    func testRawValuesExact() {
        XCTAssertEqual(ItemCategory.allCases.map(\.rawValue),
                       ["aiToolData", "worktree", "buildArtifact", "modelWeights", "systemJunk", "docker"])
    }

    func testDecodingUnknownCategoryThrows() {
        XCTAssertThrowsError(try ModelFixtures.decodeJSON(ItemCategory.self, "\"nope\""))
    }

    func testDisplayNamesNonEmpty() {
        for c in ItemCategory.allCases { XCTAssertFalse(c.displayName.isEmpty) }
    }
}
