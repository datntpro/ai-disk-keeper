import XCTest
@testable import DiskKeeperCore

final class WindsurfRulesTests: XCTestCase {
    private let f = "windsurf.json"
    private let app = "Library/Application Support/Windsurf"
    private let bundle = "com.exafunction.windsurf"

    private func populate(_ fx: FixtureHome) throws {
        for e in ["Cache", "Code Cache", "GPUCache"] { try fx.file("\(app)/\(e)/blob", bytes: 10) }
        try OtherToolRules.agedDir(fx, "\(app)/logs/old", days: 5)
        try OtherToolRules.agedDir(fx, "\(app)/User/workspaceStorage/ws-old", days: 20)
        try OtherToolRules.agedDir(fx, "\(app)/User/workspaceStorage/ws-new", days: 3)
        try fx.file(".codeium/windsurf/cascade/old.pb", bytes: 10, modified: OtherToolRules.days(20))
        try fx.file(".codeium/windsurf/cascade/new.pb", bytes: 10, modified: OtherToolRules.days(2))
        try fx.file(".codeium/windsurf/database/idx", bytes: 10)
    }

    func testWindsurfAbsentProducesNothing() async throws { try await OtherToolRules.assertAbsent(f) }

    func testWindsurfFileLoadsWithRealGuard() throws { try OtherToolRules.assertLoads(f, tool: "windsurf") }

    func testWindsurfRulesFindFixtureItems() async throws {
        let fx = try FixtureHome()
        try populate(fx)
        let r = try await OtherToolRules.run(f, fx)
        XCTAssertEqual(r.errors, [])
        let a = app
        XCTAssertEqual(r.pairs, [
            "\(a)/Cache:safe", "\(a)/Code Cache:safe", "\(a)/GPUCache:safe", "\(a)/logs/old:safe",
            "\(a)/User/workspaceStorage/ws-old:review", "\(a)/User/workspaceStorage/ws-new:keep",
            ".codeium/windsurf/cascade/old.pb:review", ".codeium/windsurf/cascade/new.pb:keep",
            ".codeium/windsurf/database:review",
        ].sorted())
    }

    func testElectronCachesSafeAndRequireQuit() async throws {
        let fx = try FixtureHome()
        try populate(fx)
        let r = try await OtherToolRules.run(f, fx)
        let caches = r.items.filter { $0.ruleID == "windsurf.electron-cache" }
        XCTAssertEqual(caches.count, 3)
        for c in caches { XCTAssertEqual(c.tier, .safe); XCTAssertEqual(c.requiresAppQuit, bundle) }
    }

    func testWorkspaceStorageReviewAndKeepWhenFresh() async throws {
        let fx = try FixtureHome()
        try populate(fx)
        let r = try await OtherToolRules.run(f, fx)
        XCTAssertEqual(r.tier("\(app)/User/workspaceStorage/ws-old"), .review)
        XCTAssertEqual(r.tier("\(app)/User/workspaceStorage/ws-new"), .keep)
    }

    func testAppLogsRequireQuit() async throws {
        let fx = try FixtureHome()
        try populate(fx)
        let r = try await OtherToolRules.run(f, fx)
        let logs = r.items.filter { $0.ruleID == "windsurf.app-logs" }
        XCTAssertFalse(logs.isEmpty)
        for l in logs { XCTAssertEqual(l.requiresAppQuit, "com.exafunction.windsurf") }
    }

    func testWindsurfProtectedFilesNeverItems() async throws {
        try await OtherToolRules.assertProtected(f, files: [
            ".codeium/windsurf/memories/m.pb", ".codeium/windsurf/mcp_config.json", ".codeium/windsurf/global_rules.md",
            ".codeium/config.json", ".codeium/windsurf/user_settings.pb", "\(app)/User/globalStorage/state.vscdb", "\(app)/User/settings.json",
            "\(app)/Cookies", "\(app)/Local Storage/l/1", "\(app)/Session Storage/1", "\(app)/IndexedDB/d/1",
            "\(app)/Local State", "\(app)/Preferences",
        ])
    }

    func testWindsurfReadOnly() async throws { try await OtherToolRules.assertReadOnly(f, populate: populate) }
}
