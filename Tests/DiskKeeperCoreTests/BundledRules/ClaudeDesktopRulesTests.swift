import XCTest
@testable import DiskKeeperCore

final class ClaudeDesktopRulesTests: XCTestCase {
    private var fixture: FixtureHome!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let A = "Library/Application Support/Claude"
    private let bundleID = "com.anthropic.claudefordesktop"

    override func setUpWithError() throws { fixture = try FixtureHome() }
    override func tearDown() { fixture = nil }

    private func days(_ d: Double) -> Date { now.addingTimeInterval(-d * 86_400) }
    private func run() async throws -> HarnessResult {
        try await RuleHarness.run(bundledFile: "claude-desktop.json", fixture: fixture, now: now)
    }

    func testVmBundleIsOneReviewItemRequiringQuit() async throws {
        try fixture.file("\(A)/vm_bundles/claudevm.bundle/rootfs.img", bytes: 4096, modified: days(40))
        try fixture.file("\(A)/vm_bundles/other.txt")
        let r = try await run()
        XCTAssertEqual(r.items.count, 1)
        let item = try XCTUnwrap(r.item(fixture.abs("\(A)/vm_bundles/claudevm.bundle")))
        XCTAssertEqual(item.requiresAppQuit, bundleID)
        XCTAssertEqual(item.tier, .review)
        XCTAssertEqual(item.category, .aiToolData)
    }

    func testBundledClaudeCodeVersionsTiers() async throws {
        for (n, d) in [("1.0.1", 2.0), ("1.0.0", 30.0)] {
            try fixture.file("\(A)/claude-code/\(n)/x", modified: days(d))
            try fixture.dir("\(A)/claude-code/\(n)", modified: days(d))
        }
        try fixture.file("\(A)/claude-code-vm/2.0/x", modified: days(30))
        try fixture.dir("\(A)/claude-code-vm/2.0", modified: days(30))
        let r = try await run()
        XCTAssertEqual(r.tier(fixture.abs("\(A)/claude-code/1.0.1")), .keep)
        XCTAssertEqual(r.tier(fixture.abs("\(A)/claude-code/1.0.0")), .review)
        XCTAssertEqual(r.tier(fixture.abs("\(A)/claude-code-vm/2.0")), .review)
        XCTAssertTrue(r.items.allSatisfy { $0.requiresAppQuit == bundleID })
    }

    func testWebCachesSafe() async throws {
        let names = ["Cache", "Code Cache", "GPUCache", "DawnGraphiteCache", "DawnWebGPUCache",
                     "GraphiteDawnCache", "GPUPersistentCache", "Shared Dictionary"]
        for n in names { try fixture.file("\(A)/\(n)/x", modified: now) }
        let r = try await run()
        XCTAssertEqual(r.items.count, 8)
        for n in names {
            let item = try XCTUnwrap(r.item(fixture.abs("\(A)/\(n)")), n)
            XCTAssertEqual(item.tier, .safe, n)
            XCTAssertEqual(item.requiresAppQuit, bundleID, n)
        }
    }

    func testCrashpadCompletedAndPendingOnly() async throws {
        try fixture.file("\(A)/Crashpad/completed/a.dmp")
        try fixture.file("\(A)/Crashpad/pending/b.dmp")
        try fixture.file("\(A)/Crashpad/settings.dat")
        let r = try await run()
        XCTAssertEqual(r.paths, [fixture.abs("\(A)/Crashpad/completed"), fixture.abs("\(A)/Crashpad/pending")])
    }

    func testProtectedDesktopFilesNeverItems() async throws {
        let rels = ["config.json", "Cookies", "Local Storage/leveldb/x", "IndexedDB/x", "git-shadow/x",
                    "claude_desktop_config.json", "Session Storage/x", "Local State", "Preferences", "ant-did",
                    "claude-code-sessions/s", "local-agent-mode-sessions/s"]
        for r in rels { try fixture.file("\(A)/\(r)", modified: days(100)) }
        let loaded = RuleHarness.loadAllBundled(fixture: fixture)
        let g = try ScanGuard(environment: fixture.env, protectPatterns: loaded.protectPatterns)
        let result = try await run()
        for r in rels {
            let p = fixture.abs("\(A)/\(r)")
            if case .allowed = g.check(p) { XCTFail("\(r) must be protected") }
            XCTAssertFalse(result.paths.contains { $0 == p || $0.hasPrefix(p + "/") }, r)
        }
        XCTAssertTrue(result.items.isEmpty)
    }

    func testAbsentAppProducesNothing() async throws {
        let r = try await run()
        XCTAssertTrue(r.items.isEmpty && r.warnings.isEmpty && r.loadErrors.isEmpty)
    }

    func testFileLoadsWithRealGuard() async throws {
        let r = try await run()
        XCTAssertTrue(r.loadErrors.isEmpty)
        let loaded = RuleHarness.loadAllBundled(fixture: fixture)
        let mine = loaded.allRules.filter { $0.tool.rawValue == "claude-desktop" }
        XCTAssertEqual(mine.count, 5)
        XCTAssertTrue(mine.allSatisfy { $0.rule.id.hasPrefix("claude-desktop.") })
    }
}
