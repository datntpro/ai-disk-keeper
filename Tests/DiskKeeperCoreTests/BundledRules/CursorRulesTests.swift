import XCTest
@testable import DiskKeeperCore

final class CursorRulesTests: XCTestCase {
    private let f = "cursor.json"
    private let app = "Library/Application Support/Cursor"
    private let bundle = "com.todesktop.230313mzl4w4u92"
    private var days: (Double) -> Date { OtherToolRules.days }

    private func populate(_ fx: FixtureHome) throws {
        for e in ["Cache", "Code Cache", "GPUCache", "CachedData"] { try fx.file("\(app)/\(e)/blob", bytes: 10) }
        try OtherToolRules.agedDir(fx, "\(app)/logs/old", days: 5)
        try fx.file("\(app)/logs/new/main.log", modified: OtherToolRules.days(0.1))
        try fx.dir("\(app)/logs/new", modified: OtherToolRules.days(0.1))
        try OtherToolRules.agedDir(fx, "\(app)/User/workspaceStorage/ws-old", days: 20)
        try OtherToolRules.agedDir(fx, "\(app)/User/workspaceStorage/ws-new", days: 3)
        try OtherToolRules.agedDir(fx, "\(app)/User/History/h1", days: 20)
        try fx.file("\(app)/CachedExtensionVSIXs/x.vsix", bytes: 10)
    }

    func testCursorAbsentProducesNothing() async throws { try await OtherToolRules.assertAbsent(f) }

    func testCursorFileLoadsWithRealGuard() throws { try OtherToolRules.assertLoads(f, tool: "cursor") }

    func testCursorRulesFindFixtureItems() async throws {
        let fx = try FixtureHome()
        try populate(fx)
        // Installed extensions are not caches.
        try fx.file(".cursor/extensions/ext/package.json")
        let r = try await OtherToolRules.run(f, fx)
        XCTAssertEqual(r.errors, [])
        let a = app
        XCTAssertEqual(r.pairs, [
            "\(a)/CachedData:safe", "\(a)/CachedExtensionVSIXs:safe", "\(a)/Cache:safe", "\(a)/Code Cache:safe", "\(a)/GPUCache:safe",
            "\(a)/User/History/h1:review", "\(a)/User/workspaceStorage/ws-new:keep", "\(a)/User/workspaceStorage/ws-old:review",
            "\(a)/logs/new:keep", "\(a)/logs/old:safe",
        ].sorted())
    }

    func testElectronCachesSafeAndRequireQuit() async throws {
        let fx = try FixtureHome()
        try populate(fx)
        let r = try await OtherToolRules.run(f, fx)
        let caches = r.items.filter { $0.ruleID == "cursor.electron-cache" }
        XCTAssertEqual(caches.count, 4)
        for c in caches {
            XCTAssertEqual(c.tier, .safe)
            XCTAssertEqual(c.requiresAppQuit, bundle)
        }
    }

    func testWorkspaceStorageReviewAndKeepWhenFresh() async throws {
        let fx = try FixtureHome()
        try populate(fx)
        let r = try await OtherToolRules.run(f, fx)
        XCTAssertEqual(r.tier("\(app)/User/workspaceStorage/ws-old"), .review)
        XCTAssertEqual(r.tier("\(app)/User/workspaceStorage/ws-new"), .keep)
        XCTAssertEqual(r.item("\(app)/User/workspaceStorage/ws-old")?.requiresAppQuit, bundle)
    }

    func testAppLogsRequireQuit() async throws {
        let fx = try FixtureHome()
        try populate(fx)
        let r = try await OtherToolRules.run(f, fx)
        let logs = r.items.filter { $0.ruleID == "cursor.app-logs" }
        XCTAssertFalse(logs.isEmpty)
        for l in logs { XCTAssertEqual(l.requiresAppQuit, "com.todesktop.230313mzl4w4u92") }
    }

    func testCursorProtectedFilesNeverItems() async throws {
        try await OtherToolRules.assertProtected(f, files: [
            "\(app)/User/globalStorage/state.vscdb", "\(app)/User/globalStorage/x/y", "\(app)/User/settings.json",
            "\(app)/User/keybindings.json", "\(app)/User/snippets/a.json", "\(app)/User/profiles/p/settings.json",
            "\(app)/Cookies", "\(app)/Cookies-journal", "\(app)/Local Storage/leveldb/1", "\(app)/Session Storage/1",
            "\(app)/IndexedDB/db/1", "\(app)/Local State", "\(app)/Preferences",
            ".cursor/mcp.json", ".cursor/settings.json", ".cursor/rules/r.mdc",
        ])
    }

    func testCursorReadOnly() async throws { try await OtherToolRules.assertReadOnly(f, populate: populate) }
}
