import XCTest
@testable import DiskKeeperCore

final class OrcaRulesTests: XCTestCase {
    private let f = "orca.json"
    private let app = "Library/Application Support/orca"
    private let bundle = "com.stablyai.orca"

    private func populate(_ fx: FixtureHome) throws {
        for e in ["Cache", "Code Cache", "GPUCache"] { try fx.file("\(app)/\(e)/blob", bytes: 10) }
        try OtherToolRules.agedDir(fx, "\(app)/logs/old", days: 5)
        try fx.file("\(app)/logs/fresh.log", modified: OtherToolRules.days(0.1))
        try fx.file("\(app)/Crashpad/completed/a.dmp", bytes: 10)
        try fx.file("\(app)/Crashpad/pending/b.dmp", bytes: 10)
        try fx.file("\(app)/Crashpad/settings.dat")
        // Runtime state not proven regenerable: never items.
        try fx.file("\(app)/daemon-host/x")
        try fx.file("\(app)/plugins-data/x")
    }

    func testOrcaAbsentProducesNothing() async throws { try await OtherToolRules.assertAbsent(f) }

    func testOrcaFileLoadsWithRealGuard() throws { try OtherToolRules.assertLoads(f, tool: "orca") }

    func testOrcaRulesFindFixtureItems() async throws {
        let fx = try FixtureHome()
        try populate(fx)
        let r = try await OtherToolRules.run(f, fx)
        XCTAssertEqual(r.errors, [])
        let a = app
        XCTAssertEqual(r.pairs, [
            "\(a)/Cache:safe", "\(a)/Code Cache:safe", "\(a)/GPUCache:safe",
            "\(a)/logs/old:safe", "\(a)/logs/fresh.log:keep",
            "\(a)/Crashpad/completed:safe", "\(a)/Crashpad/pending:safe",
        ].sorted())
    }

    func testElectronCachesSafeAndRequireQuit() async throws {
        let fx = try FixtureHome()
        try populate(fx)
        let r = try await OtherToolRules.run(f, fx)
        let caches = r.items.filter { $0.ruleID == "orca.electron-cache" }
        XCTAssertEqual(caches.count, 3)
        for c in caches { XCTAssertEqual(c.tier, .safe); XCTAssertEqual(c.requiresAppQuit, bundle) }
    }

    func testOrcaClaudeProfilesProtected() async throws {
        try await OtherToolRules.assertProtected(f, files: [
            "\(app)/claude-profiles/u/home/projects/p/x.jsonl", "\(app)/claude-profiles/u/home/projects/p/memory/m.md",
            "\(app)/claude-profiles/u/home/.claude.json", "\(app)/codex-runtime-home/auth.json",
            "\(app)/settings.json", "\(app)/orca-data.db", "\(app)/orca-data.db-wal", "\(app)/x.sqlite",
            "\(app)/ai-vault/v", "\(app)/profiles/p", "\(app)/bot-memory-history/h", "\(app)/terminal-history/t",
            "\(app)/agent-session-attachments/a", "\(app)/Partitions/p/Cookies", "\(app)/Cookies", "\(app)/Local Storage/l/1",
            "\(app)/Session Storage/1", "\(app)/IndexedDB/d/1", "\(app)/Local State", "\(app)/Preferences",
        ])
    }

    func testOrcaHasNoWorktreeRule() throws {
        let fx = try FixtureHome()
        let env = fx.env
        guard let url = CoreResources.rulesDirectoryURL?.appendingPathComponent(f) else { return XCTFail("missing") }
        let tmp = try TemporaryDirectory()
        try tmp.file(f, contents: try Data(contentsOf: url))
        let loaded = RuleLoader(environment: env, bundledRulesDirectory: tmp.url, userRulesDirectory: nil,
                                guardFactory: ScanGuard.loaderFactory(environment: env)).load()
        XCTAssertEqual(loaded.errors, [])
        for r in loaded.allRules {
            XCTAssertFalse(r.rule.paths.contains { $0.raw.contains("workspaces") }, r.rule.id)
            XCTAssertFalse(r.rule.explanation.lowercased().contains("worktree"), r.rule.id)
            XCTAssertNotEqual(r.rule.category, .worktree, r.rule.id)
        }
    }

    func testOrcaReadOnly() async throws { try await OtherToolRules.assertReadOnly(f, populate: populate) }
}
