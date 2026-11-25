import XCTest
@testable import DiskKeeperCore

final class PathNormalizationTests: XCTestCase {
    func testLexicalCollapsesDotsSlashesAndTrailingSlash() {
        XCTAssertEqual(PathNormalization.lexical("/a//b/./c/"), "/a/b/c")
        XCTAssertEqual(PathNormalization.lexical("/a/b/../c"), "/a/c")
        XCTAssertEqual(PathNormalization.lexical("/.."), "/")
        XCTAssertEqual(PathNormalization.lexical("/"), "/")
        XCTAssertEqual(PathNormalization.lexical(""), "")
        XCTAssertEqual(PathNormalization.lexical("rel/../x"), "rel/../x")
    }

    func testLexicalPreservesPrivatePrefixCaseAndUnicode() {
        let p = "/private/tmp/X/Cafe\u{301}"
        XCTAssertEqual(PathNormalization.lexical(p), p)
    }

    func testContainsParentReference() {
        XCTAssertTrue(PathNormalization.containsParentReference("/a/../b"))
        XCTAssertFalse(PathNormalization.containsParentReference("/a/..b"))
        XCTAssertFalse(PathNormalization.containsParentReference("/a/b.."))
    }

    func testComponents() {
        XCTAssertEqual(PathNormalization.components("/").count, 0)
        XCTAssertEqual(PathNormalization.components("/a/b").map(String.init), ["a", "b"])
    }

    func testSlashFollowedByCombiningMarkIsStillASeparator() {
        XCTAssertEqual(PathNormalization.components("/a/\u{301}").map(String.init), ["a", "\u{301}"])
        XCTAssertTrue(PathNormalization.containsParentReference("/a/../\u{301}"))
        XCTAssertTrue(PathNormalization.containsParentReference("/a/\u{301}/.."))
        XCTAssertEqual(PathNormalization.lexical("/a/\u{301}/../b"), "/a/b")
        XCTAssertTrue(PathNormalization.isAbsolute("/\u{301}x"))
        XCTAssertTrue(PathNormalization.containsNUL("/a\0\u{301}"))
    }
}
