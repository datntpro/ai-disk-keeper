import XCTest
@testable import DiskKeeperCore

final class GeminiRulesTests: XCTestCase {
    private let f = "gemini.json"
    private let app = "Library/Application Support/Antigravity"
    private let bundle = "com.google.antigravity"

    private func populate(_ fx: FixtureHome) throws {
        try OtherToolRules.agedDir(fx, ".gemini/tmp/proj-old", days: 40)
        try OtherToolRules.agedDir(fx, ".gemini/tmp/proj-mid", days: 15)
        try OtherToolRules.agedDir(fx, ".gemini/tmp/proj-new", days: 2)
        try fx.file(".gemini/antigravity/cache/c", bytes: 10)
        try fx.file(".gemini/antigravity/crashes/c.dmp", bytes: 10)
        for e in ["Cache", "Code Cache", "GPUCache", "GraphiteDawnCache"] { try fx.file("\(app)/\(e)/blob", bytes: 10) }
        try OtherToolRules.agedDir(fx, "\(app)/logs/old", days: 5)
        try OtherToolRules.agedDir(fx, "\(app)/User/workspaceStorage/ws-old", days: 20)
        try OtherToolRules.agedDir(fx, "\(app)/User/workspaceStorage/ws-new", days: 3)
    }

    func testGeminiAbsentProducesNothing() async throws { try await OtherToolRules.assertAbsent(f) }

    func testGeminiFileLoadsWithRealGuard() throws { try OtherToolRules.assertLoads(f, tool: "gemini") }

    func testGeminiCliTmpAndAntigravity() async throws {
        let fx = try FixtureHome()
        try populate(fx)
        // Not proven regenerable: never targeted.
        try fx.file(".gemini/antigravity/bin/x")
        try fx.file(".gemini/antigravity/plugin_data/x")
        let r = try await OtherToolRules.run(f, fx)
        XCTAssertEqual(r.errors, [])
        let a = app
        XCTAssertEqual(r.pairs, [
            ".gemini/tmp/proj-old:safe", ".gemini/tmp/proj-mid:review", ".gemini/tmp/proj-new:keep",
            ".gemini/antigravity/cache:safe", ".gemini/antigravity/crashes:safe",
            "\(a)/Cache:safe", "\(a)/Code Cache:safe", "\(a)/GPUCache:safe", "\(a)/GraphiteDawnCache:safe",
            "\(a)/logs/old:safe", "\(a)/User/workspaceStorage/ws-old:review", "\(a)/User/workspaceStorage/ws-new:keep",
        ].sorted())
    }

    func testElectronCachesSafeAndRequireQuit() async throws {
        let fx = try FixtureHome()
        try populate(fx)
        let r = try await OtherToolRules.run(f, fx)
        let caches = r.items.filter { $0.ruleID == "gemini.antigravity-electron-cache" }
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
    }

    func testAppLogsRequireQuit() async throws {
        let fx = try FixtureHome()
        try populate(fx)
        let r = try await OtherToolRules.run(f, fx)
        let logs = r.items.filter { $0.ruleID == "gemini.antigravity-logs" }
        XCTAssertFalse(logs.isEmpty)
        for l in logs { XCTAssertEqual(l.requiresAppQuit, "com.google.antigravity") }
    }

    func testGeminiProtectedFilesNeverItems() async throws {
        try await OtherToolRules.assertProtected(f, files: [
            ".gemini/oauth_creds.json", ".gemini/settings.json", ".gemini/.env", ".gemini/config/mcp_config.json",
            ".gemini/antigravity/conversation_summaries.db", ".gemini/antigravity/conversation_summaries.db-wal",
            ".gemini/antigravity/a.pbtxt", ".gemini/antigravity/installation_id",
            ".gemini/antigravity/conversations/c.pb", ".gemini/antigravity/brain/b/x", ".gemini/antigravity/daemon/d",
            ".gemini/commands/c.toml", ".gemini/extensions/e/x",
            "\(app)/User/globalStorage/state.vscdb", "\(app)/User/settings.json", "\(app)/User/snippets/s.json",
            "\(app)/User/profiles/p/x", "\(app)/Cookies", "\(app)/Local Storage/leveldb/1", "\(app)/Session Storage/1",
            "\(app)/IndexedDB/db/1", "\(app)/Local State", "\(app)/Preferences",
        ])
    }

    func testGeminiReadOnly() async throws { try await OtherToolRules.assertReadOnly(f, populate: populate) }
}
