import XCTest
@testable import DiskKeeperCore

final class PathKeyTests: XCTestCase {
    func testAliasesCanonicalize() {
        let k = PathCanonicalizer.key("/private/tmp/x")
        XCTAssertEqual(PathCanonicalizer.key("/tmp/x"), k)
        XCTAssertEqual(PathCanonicalizer.key("/TMP/x"), k)
        XCTAssertEqual(PathCanonicalizer.key("/System/Volumes/Data/private/tmp/x"), k)
        XCTAssertEqual(PathCanonicalizer.key("/etc/hosts"), PathCanonicalizer.key("/private/etc/hosts"))
        XCTAssertEqual(PathCanonicalizer.key("/var/x"), PathCanonicalizer.key("/private/var/x"))
    }

    func testFirmlinkDataPrefixStripped() {
        XCTAssertEqual(PathCanonicalizer.key("/System/Volumes/Data/Users/a"), PathCanonicalizer.key("/Users/a"))
        XCTAssertEqual(PathCanonicalizer.key("/System/Volumes/Data").components, [])
    }

    func testCaseAndNormalizationFolding() {
        XCTAssertEqual(PathCanonicalizer.key("/x/Caf\u{E9}"), PathCanonicalizer.key("/x/CAFE\u{301}"))
    }

    func testGlob() {
        func m(_ p: String, _ c: String) -> Bool { GlobMatcher.matches(pattern: p, component: c) }
        XCTAssertTrue(m("*.pem", "a.pem"))
        XCTAssertFalse(m("*.pem", "a.pemx"))
        XCTAssertTrue(m("*", ".hidden"))
        XCTAssertTrue(m("*", ""))
        XCTAssertTrue(m("a?c", "abc"))
        XCTAssertFalse(m("a?c", "ac"))
        XCTAssertTrue(m("[a-c]x", "bx"))
        XCTAssertFalse(m("[a-c]x", "dx"))
        XCTAssertTrue(m("[!a]x", "bx"))
        XCTAssertFalse(m("[!a]x", "ax"))
        XCTAssertTrue(m("\\*", "*"))
        XCTAssertFalse(m("\\*", "a"))
        XCTAssertTrue(m("[abc", "[abc"))
        XCTAssertTrue(m("a\\", "a\\"))
        XCTAssertFalse(m("", "x"))
        XCTAssertTrue(m("", ""))
        XCTAssertTrue(m("a*b*c", "aXXbYYc"))
        XCTAssertFalse(m("a*b*c", "aXXbYY"))
        XCTAssertTrue(m("id_rsa*", "id_rsa.pub"))
        XCTAssertFalse(m("id_rsa*", "id_utils"))
        XCTAssertTrue(m("[]]", "]"))
        XCTAssertTrue(m("[a-]", "-"))
    }
}
