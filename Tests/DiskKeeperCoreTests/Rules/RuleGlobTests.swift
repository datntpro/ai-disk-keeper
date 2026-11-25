import XCTest
@testable import DiskKeeperCore

final class RuleGlobTests: XCTestCase {
    private func g(_ p: String) throws -> RuleGlob { try RuleGlob(p) }

    func testMatchesStarQuestionClassRangeNegationEscape() throws {
        XCTAssertTrue(try g("*").matches("anything"))
        XCTAssertTrue(try g("*").matches(""))
        XCTAssertTrue(try g("a*c").matches("abbbc"))
        XCTAssertFalse(try g("a*c").matches("abbbd"))
        XCTAssertTrue(try g("*a*b*").matches("xxaxxbxx"))
        XCTAssertTrue(try g("a?c").matches("abc"))
        XCTAssertFalse(try g("a?c").matches("ac"))
        XCTAssertTrue(try g("[abc]x").matches("bx"))
        XCTAssertFalse(try g("[abc]x").matches("dx"))
        XCTAssertTrue(try g("[a-c]x").matches("bx"))
        XCTAssertTrue(try g("[!a-c]x").matches("dx"))
        XCTAssertFalse(try g("[!a-c]x").matches("bx"))
        XCTAssertTrue(try g(#"a\*b"#).matches("a*b"))
        XCTAssertFalse(try g(#"a\*b"#).matches("axb"))
        XCTAssertTrue(try g(".aider.tags.cache.v*").matches(".aider.tags.cache.v3"))
        XCTAssertTrue(try g("claude-*").matches("claude-1234"))
        XCTAssertFalse(try g("claude-*").matches("xclaude-1"))
    }

    func testCaseInsensitive() throws {
        XCTAssertTrue(try g("*.JSONL").matches("a.jsonl"))
        XCTAssertTrue(try g("*.jsonl").matches("A.JSONL"))
        XCTAssertTrue(try g("[A-C]x").matches("bX"))
    }

    func testUnicodeNormalizationInsensitive() throws {
        let nfc = "caf\u{00E9}", nfd = "cafe\u{0301}"
        XCTAssertTrue(try g(nfc).matches(nfd))
        XCTAssertTrue(try g(nfd).matches(nfc))
        XCTAssertTrue(try g("caf*").matches(nfd))
    }

    func testRejects() {
        let cases: [(String, String)] = [
            ("", "empty"), ("a/b", "'/'"), ("**", "'**'"), ("ab[abc", "unclosed '[' at position 3"),
            ("[]", "empty class at position 1"), ("[!]", "empty class at position 1"),
            ("x[z-a]", "reversed range 'z-a' at position 2"), ("a\\", "trailing '\\' at position 2"),
        ]
        for (pattern, expected) in cases {
            XCTAssertThrowsError(try RuleGlob(pattern), pattern) { error in
                XCTAssertTrue("\(error)".contains(expected), "\(pattern): \(error)")
            }
        }
    }

    func testCodableValidates() throws {
        XCTAssertEqual(try JSONDecoder().decode(RuleGlob.self, from: Data(#""*.x""#.utf8)).pattern, "*.x")
        XCTAssertThrowsError(try JSONDecoder().decode(RuleGlob.self, from: Data(#""[""#.utf8)))
    }
}
