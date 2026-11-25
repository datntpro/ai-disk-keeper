import XCTest
@testable import DiskKeeperCore

final class PathClaimSetTests: XCTestCase {
    func testEqualInsideContainsConflicts() {
        var set = PathClaimSet()
        XCTAssertNil(set.claim("/a/b"))
        XCTAssertEqual(set.claim("/a/b"), .equal("/a/b"))
        XCTAssertEqual(set.claim("/a/b/c"), .inside("/a/b"))
        XCTAssertEqual(set.claim("/a"), .contains("/a/b"))
    }

    func testSiblingsDoNotConflict() {
        var set = PathClaimSet()
        XCTAssertNil(set.claim("/a/b"))
        XCTAssertNil(set.claim("/a/bc"))
        XCTAssertNil(set.claim("/a/c"))
    }

    func testAliasAndCaseFolding() {
        var set = PathClaimSet()
        XCTAssertNil(set.claim("/tmp/x"))
        XCTAssertEqual(set.claim("/private/tmp/X"), .equal("/tmp/x"))
    }

    func testCombiningMarkAfterSlashIsSeparateComponent() {
        var set = PathClaimSet()
        XCTAssertNil(set.claim("/a"))
        XCTAssertEqual(set.claim("/a/\u{301}"), .inside("/a"))
    }

    func testRootClaimConflictsWithEverything() {
        var set = PathClaimSet()
        XCTAssertNil(set.claim("/a/b"))
        XCTAssertEqual(set.claim("/"), .contains("/a/b"))
    }
}
