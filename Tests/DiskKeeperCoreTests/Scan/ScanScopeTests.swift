import XCTest
@testable import DiskKeeperCore

final class ScanScopeTests: XCTestCase {
    private func item(_ path: String, tool: ToolID = "t") -> ScanItem {
        ScanItem(url: URL(fileURLWithPath: path), displayName: "x", tool: tool, category: .aiToolData,
                 sizeAllocated: 1, sizeLogical: 1, fileCount: 1, lastModified: nil, tier: .safe,
                 explanation: "x", ruleID: "t.r")
    }

    func testUnrestrictedAllowsEverything() {
        XCTAssertTrue(ScanScope.unrestricted.allows(item("/a/b")))
    }

    func testEqualInsideAndContainsAreRejected() {
        let s = ScanScope(excludedPaths: ["/h/.claude/projects/my-app"])
        XCTAssertFalse(s.allows(item("/h/.claude/projects/my-app")))
        XCTAssertFalse(s.allows(item("/h/.claude/projects/my-app/sub/file")))
        XCTAssertFalse(s.allows(item("/h/.claude/projects")), "an item containing an excluded path must go")
        XCTAssertTrue(s.allows(item("/h/.claude/projects/other")))
        XCTAssertTrue(s.allows(item("/h/.claude/projects/my-app-2")), "sibling with common name prefix is fine")
    }

    func testCaseAndAliasFolding() {
        let s = ScanScope(excludedPaths: ["/Users/Me/Cache"])
        XCTAssertFalse(s.allows(item("/users/me/CACHE/x")))
        let t = ScanScope(excludedPaths: ["/tmp/x"])
        XCTAssertFalse(t.allows(item("/private/tmp/x/y")))
    }

    func testDisabledTool() {
        let s = ScanScope(disabledTools: ["t"])
        XCTAssertFalse(s.allows(item("/a", tool: "t")))
        XCTAssertTrue(s.allows(item("/a", tool: "u")))
    }

    func testSymlinkVariantsOfExcludedPathsAreHonoured() throws {
        let tmp = try TemporaryDirectory()
        try tmp.dir("real/projects/app")
        try tmp.symlink("link", to: tmp.path("real"))
        // exclude the real path, item via the link
        let a = ScanScope(excludedPaths: [tmp.path("real/projects/app")])
        XCTAssertFalse(a.allows(item(tmp.path("link/projects/app"))))
        XCTAssertFalse(a.allows(item(tmp.path("link/projects"))), "containing item via link")
        XCTAssertFalse(a.allows(item(tmp.path("link/projects/app/sub/new"))), "not-yet-existing tail")
        XCTAssertTrue(a.allows(item(tmp.path("link/projects/other"))))
        // exclude via the link, item at the real path
        let b = ScanScope(excludedPaths: [tmp.path("link/projects/app")])
        XCTAssertFalse(b.allows(item(tmp.path("real/projects/app"))))
        XCTAssertTrue(b.allows(item(tmp.path("real/projects/other"))))
    }

    func testPrivateAliasWithSymlinkedTmp() throws {
        let tmp = try TemporaryDirectory()   // resolved /private/var/... path
        try tmp.dir("x/y")
        let s = ScanScope(excludedPaths: [tmp.path("x")])
        // the unresolved /var spelling of the same directory
        let aliased = tmp.path("x/y").replacingOccurrences(of: "/private/var", with: "/var")
        XCTAssertFalse(s.allows(item(aliased)))
    }
}
