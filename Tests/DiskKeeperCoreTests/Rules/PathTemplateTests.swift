import XCTest
@testable import DiskKeeperCore

final class PathTemplateTests: XCTestCase {
    private let env = PathEnvironment(home: "/H", temporaryDirectory: "/T/x", variables: [:])

    private func expand(_ raw: String, vars: [String: String] = [:], globs: Bool = false) throws -> PathExpansion {
        var e = env
        e.variables = vars
        return try PathTemplate(raw, allowGlobs: globs).expand(in: e)
    }

    private func assertRejects(_ raw: String, globs: Bool = false, _ contains: String? = nil,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try PathTemplate(raw, allowGlobs: globs), raw, file: file, line: line) { error in
            if let contains {
                XCTAssertTrue("\(error)".contains(contains), "\(error)", file: file, line: line)
            }
        }
    }

    func testExpandsAllRootTokens() throws {
        XCTAssertEqual(try expand("~"), .path("/H"))
        XCTAssertEqual(try expand("~/a"), .path("/H/a"))
        XCTAssertEqual(try expand("$HOME/a"), .path("/H/a"))
        XCTAssertEqual(try expand("$TMPDIR/a"), .path("/T/x/a"))
        XCTAssertEqual(try expand("$APP_SUPPORT/Cursor"), .path("/H/Library/Application Support/Cursor"))
        XCTAssertEqual(try expand("$CACHES/c"), .path("/H/Library/Caches/c"))
        XCTAssertEqual(try expand("$LOGS/l"), .path("/H/Library/Logs/l"))
        XCTAssertEqual(try expand("$CONTAINERS/c"), .path("/H/Library/Containers/c"))
        XCTAssertEqual(try expand("$GROUP_CONTAINERS/g"), .path("/H/Library/Group Containers/g"))
        XCTAssertEqual(try expand("$TMPDIR"), .path("/T/x"))
    }

    func testEnvVarWithFallback() throws {
        let raw = "${CLAUDE_CONFIG_DIR:-~/.claude}/projects"
        XCTAssertEqual(try expand(raw), .path("/H/.claude/projects"))
        XCTAssertEqual(try expand(raw, vars: ["CLAUDE_CONFIG_DIR": "/x"]), .path("/x/projects"))
        XCTAssertEqual(try expand(raw, vars: ["CLAUDE_CONFIG_DIR": "/x/"]), .path("/x/projects"))
    }

    func testEnvVarUnsetWithoutFallbackIsUnavailable() throws {
        XCTAssertEqual(try expand("${HF_HOME}/hub"), .unavailable(reason: "HF_HOME is not set"))
        XCTAssertEqual(try expand("${HF_HOME}/hub", vars: ["HF_HOME": ""]), .unavailable(reason: "HF_HOME is not set"))
    }

    func testEnvVarRelativeOrDotDotValueTreatedAsUnset() throws {
        for bad in ["relative/dir", "/a/../b", "/", "/a/./b"] {
            XCTAssertEqual(try expand("${V}/x", vars: ["V": bad]), .unavailable(reason: "V is not set"), bad)
            XCTAssertEqual(try expand("${V:-~/d}/x", vars: ["V": bad]), .path("/H/d/x"), bad)
        }
    }

    func testRejectsDotDot() {
        assertRejects("~/a/../b", "..")
        assertRejects("~/./b")
    }

    func testRejectsRelative() {
        assertRejects("relative/path", "must start with")
        assertRejects("~user/x", "must start with")
        assertRejects("")
    }

    func testRejectsUsersAbsolute() {
        assertRejects("/Users/me/x", "must start with")
        assertRejects("/etc/passwd")
        assertRejects("$TMPDIRX/a")
        assertRejects("/tmpx")
    }

    func testRejectsTrailingSlash() {
        assertRejects("~/a/")
        assertRejects("~/")
        assertRejects("~//a")
    }

    func testRejectsGlobInPaths() {
        assertRejects("~/a*", "glob")
        assertRejects("~/a?/b")
        assertRejects("~/[a]")
    }

    func testRejectsNestedEnvFallback() {
        assertRejects("${A:-${B:-~/x}}/y")
        assertRejects("${a}/y", "invalid variable name")
        assertRejects("${A")
    }

    func testAcceptsPrivateTmpAndTmp() throws {
        XCTAssertEqual(try expand("/private/tmp"), .path("/private/tmp"))
        XCTAssertEqual(try expand("/private/tmp/claude-1"), .path("/private/tmp/claude-1"))
        XCTAssertEqual(try expand("/tmp/x"), .path("/tmp/x"))
    }

    func testRejectsDollarMidPath() {
        assertRejects("~/a/$HOME")
        assertRejects("~/a/~b")
        assertRejects("~/a\\b")
    }

    func testProtectTemplateAllowsGlobAndTrailingDoubleStar() throws {
        XCTAssertEqual(try expand("~/.claude/settings*.json", globs: true), .path("/H/.claude/settings*.json"))
        XCTAssertEqual(try expand("~/.claude/skills/**", globs: true), .path("/H/.claude/skills/**"))
    }

    func testProtectTemplateRejectsInnerDoubleStar() {
        assertRejects("~/**/x", globs: true, "**")
        assertRejects("~/a**", globs: true)
        assertRejects("~/[abc", globs: true)
    }

    func testExpandPatternEscapesMachineDerivedParts() throws {
        let weird = PathEnvironment(home: "/Users/a[1]*?b", temporaryDirectory: "/T/x", variables: ["X": "/v/[a", "Y": "/y\\z"])
        func pat(_ raw: String) throws -> PathExpansion { try PathTemplate(raw, allowGlobs: true).expandPattern(in: weird) }
        XCTAssertEqual(try pat("~/.foo/**"), .path(#"/Users/a\[1\]\*\?b/.foo/**"#))
        XCTAssertEqual(try pat("$APP_SUPPORT/x/y*.json"), .path(#"/Users/a\[1\]\*\?b/Library/Application Support/x/y*.json"#))
        XCTAssertEqual(try pat("${X}/**"), .path(#"/v/\[a/**"#))
        XCTAssertEqual(try pat("${Y}/a"), .path(#"/y\\z/a"#))
        // the template's own globs (also in a fallback's components) stay unescaped
        XCTAssertEqual(try pat("${NOPE:-~/.c*}/s"), .path(#"/Users/a\[1\]\*\?b/.c*/s"#))
        // plain expansion is untouched
        XCTAssertEqual(try PathTemplate("~/.foo").expand(in: weird), .path("/Users/a[1]*?b/.foo"))
    }

    func testEnvValueIsLexicallyCleaned() throws {
        XCTAssertEqual(try expand("${V}/c", vars: ["V": "/Users/me///x//"]), .path("/Users/me/x/c"))
        XCTAssertEqual(try expand("${V}/c", vars: ["V": "/a\nb"]), .unavailable(reason: "V is not set"))
        XCTAssertEqual(try expand("${V}/c", vars: ["V": "//"]), .unavailable(reason: "V is not set"))
    }

    func testSlashFollowedByCombiningMarkIsStillASeparator() throws {
        // "/" + U+0301 is ONE Character in Swift, but the filesystem splits on the "/" byte.
        let mark = "\u{301}"
        assertRejects("~/a/../\(mark)", "..")             // ".." must not hide inside a fused Character
        assertRejects("~/a/./\(mark)")
        assertRejects("~/a/\(mark)/..", "..")
        XCTAssertEqual(try expand("~/a/\(mark)"), .path("/H/a/\(mark)"))
        XCTAssertEqual(try expand("~/a/\(mark)/b"), .path("/H/a/\(mark)/b"))
        assertRejects("~/a/\(mark)/", "trailing")
        assertRejects("~\(mark)/a")                        // a different root token, not "~"
        // forbidden / glob characters followed by a mark are still those characters
        assertRejects("~/a$\(mark)b", "forbidden")
        assertRejects("~/a~\(mark)b", "forbidden")
        assertRejects("~/a*\(mark)", "glob")
        assertRejects("~/a[\(mark)b]", "glob")
        assertRejects("~/a**\(mark)", globs: true)
        assertRejects("${V}\(mark)/x")
        XCTAssertEqual(try expand("${V:-~/a/\(mark)}/b"), .path("/H/a/\(mark)/b"))
    }

    func testEnvValueWithMarkedSeparatorIsNotTrusted() throws {
        let mark = "\u{301}"
        // ".." hidden behind a fused separator must still count as a ".." component.
        XCTAssertEqual(try expand("${V}/c", vars: ["V": "/a/../\(mark)"]), .unavailable(reason: "V is not set"))
        XCTAssertEqual(try expand("${V}/c", vars: ["V": "/a/./\(mark)x"]), .unavailable(reason: "V is not set"))
        XCTAssertEqual(try expand("${V}/c", vars: ["V": "/a/\(mark)x"]), .path("/a/\(mark)x/c"))
    }

    func testEscapeGlobEscapesMetacharactersFollowedByMarks() throws {
        let mark = "\u{301}"
        let weird = PathEnvironment(home: "/Users/a[\(mark)b*\(mark)", temporaryDirectory: "/T", variables: [:])
        let pattern = try PathTemplate("~/.x/**", allowGlobs: true).expandPattern(in: weird)
        XCTAssertEqual(pattern, .path("/Users/a\\[\(mark)b\\*\(mark)/.x/**"))
    }

    func testCodableIsSingleString() throws {
        let t = try JSONDecoder().decode(PathTemplate.self, from: Data(#""~/a""#.utf8))
        XCTAssertEqual(t.raw, "~/a")
        XCTAssertEqual(String(decoding: try JSONEncoder().encode(t), as: UTF8.self), #""~\/a""#)
        XCTAssertThrowsError(try JSONDecoder().decode(PathTemplate.self, from: Data(#""/etc""#.utf8)))
    }

    func testCurrentEnvironmentIsAbsolute() {
        let e = PathEnvironment.current()
        XCTAssertTrue(e.home.hasPrefix("/"))
        XCTAssertTrue(e.temporaryDirectory.hasPrefix("/"))
        XCTAssertFalse(e.temporaryDirectory.hasSuffix("/"))
    }
}
