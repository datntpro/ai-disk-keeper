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

    func testUnicodeCaseFolding() {
        XCTAssertEqual(PathCanonicalizer.key("/x/.\u{17F}sh"), PathCanonicalizer.key("/x/.ssh"))
    }

    func testGlobEdgeCases() {
        XCTAssertTrue(GlobMatcher.matches(pattern: "a**b", component: "aXXb"))
        XCTAssertTrue(GlobMatcher.matches(pattern: "[\\]]", component: "]"))
        XCTAssertFalse(GlobMatcher.matches(pattern: "[\\]]", component: "a"))
    }

    func testGlobMatchesWholeCharacters() {
        func m(_ p: String, _ c: String) -> Bool {
            GlobMatcher.matchesCharacters(pattern: PathCanonicalizer.fold(p), component: PathCanonicalizer.fold(c))
        }
        for e in ["\u{E9}", "e\u{301}"] {
            XCTAssertTrue(m("caf?", "caf" + e), e)
            XCTAssertTrue(m("caf[\u{E9}x]", "caf" + e), e)
            XCTAssertTrue(m("caf[e\u{301}x]", "caf" + e), e)
            XCTAssertFalse(m("caf??", "caf" + e), e)
            XCTAssertTrue(m("caf[!x]", "caf" + e), e)
            XCTAssertTrue(m("caf*", "caf" + e), e)
        }
        XCTAssertTrue(m("a?b", "a\u{1F600}b"))
        XCTAssertFalse(m("a??b", "a\u{1F600}b"))
        XCTAssertTrue(m("a?b", "a\u{1F468}\u{200D}\u{1F469}b"), "ZWJ sequence is one character")
        XCTAssertTrue(m("x?", "xa\u{308}"), "base + combining mark is one character")
        XCTAssertFalse(m("x??", "xa\u{308}"))
        XCTAssertTrue(m("[\u{1F600}-\u{1F64F}]", "\u{1F601}"))
    }

    func testEitherMatcherKeepsLiteralsBeforeCombiningMarks() {
        func m(_ p: String, _ c: String) -> Bool {
            GlobMatcher.matches(pattern: PathCanonicalizer.fold(p), component: PathCanonicalizer.fold(c))
        }
        XCTAssertFalse(GlobMatcher.matchesCharacters(pattern: "id_rsa*", component: "id_rsa\u{301}"))
        XCTAssertTrue(m("id_rsa*", "id_rsa\u{301}"))
        XCTAssertTrue(m("id_rsa*", "id_rsa\u{200D}_old"))
        XCTAssertTrue(m(".env.*", ".env.\u{301}"))
        XCTAssertTrue(m("settings*.json", "settings\u{301}.json"))
        XCTAssertTrue(m("r?", "re\u{301}"))
    }

    func testEscapeGlobEscapesMetacharacterFollowedByCombiningMark() {
        let esc = ProtectedPaths.escapeGlob("a[\u{301}b")
        XCTAssertTrue(GlobMatcher.matches(pattern: esc, component: "a[\u{301}b"))
        XCTAssertFalse(GlobMatcher.matches(pattern: esc, component: "ab"))
    }
}
