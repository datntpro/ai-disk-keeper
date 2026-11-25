import XCTest
@testable import DiskKeeperCore

final class SystemJunkRulesTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func ago(hours: Double) -> Date { now.addingTimeInterval(-hours * 3600) }
    private func ago(days: Double) -> Date { ago(hours: days * 24) }
    private let file = "system-junk.json"

    private func run(_ f: FixtureHome, over: [String: [String]] = [:], userID: uid_t = getuid()) async throws -> HarnessResult {
        try await RuleHarness.run(bundledFile: file, fixture: f, now: now, overridePaths: over, userID: userID)
    }

    private func tempOverride(_ f: FixtureHome) -> [String: [String]] {
        ["system.agent-temp": [f.tempDir, f.abs("$TMP/privtmp")]]
    }

    // MARK: crash reports

    func testCrashReportFilterOnFixtureIpsNames() async throws {
        let f = try FixtureHome()
        let d = "Library/Logs/DiagnosticReports"
        let old = ago(days: 5)
        let expected: [String: String] = [
            "\(d)/Claude-2026-11-20-101010.ips": "system.crash-reports.claude",
            "\(d)/Claude Helper (Renderer)-2026-11-20-101010.ips": "system.crash-reports.claude",
            "\(d)/ExcUserFault_Claude-2026-11-21-000000.ips": "system.crash-reports.claude-faults",
            "\(d)/claude_2026-11-20-101010_Host.cpu_resource.diag": "system.crash-reports.claude",
            "\(d)/Cursor Helper-2026-11-20-101010.ips": "system.crash-reports.cursor",
            "\(d)/ollama-2026-11-20-101010.ips": "system.crash-reports.ollama",
            "\(d)/Retired/Kiro-2026-11-19-000000.ips": "system.crash-reports.kiro",
        ]
        for p in expected.keys { try f.file(p, modified: old) }
        for p in ["Safari-2026-11-20-101010.ips", "SFA-networking.json_2026-11-25-164318_Host.diag",
                  "node-2026-11-20-101010.ips", "ExcUserFault_IMDPersistenceAgent-2026-11-20-225015.ips",
                  "Microsoft Edge-2026-11-20.ips"] {
            try f.file("\(d)/\(p)", modified: old)
        }
        let r = try await run(f)
        XCTAssertEqual(r.loadErrors, [])
        let crash = r.items.filter { $0.ruleID.hasPrefix("system.crash-reports.") }
        XCTAssertEqual(Set(crash.map(\.path)), Set(expected.keys.map { f.abs($0) }))
        for (rel, rule) in expected {
            XCTAssertEqual(r.item(f.abs(rel))?.ruleID, rule, rel)
            XCTAssertEqual(r.tier(f.abs(rel)), .safe, rel)
        }
    }

    func testCrashReportsRecentAreReview() async throws {
        let f = try FixtureHome()
        let d = "Library/Logs/DiagnosticReports"
        try f.file("\(d)/Claude-new.ips", modified: ago(hours: 2))
        try f.file("\(d)/Claude-old.ips", modified: ago(days: 3))
        let r = try await run(f)
        XCTAssertEqual(r.tier(f.abs("\(d)/Claude-new.ips")), .review)
        XCTAssertEqual(r.tier(f.abs("\(d)/Claude-old.ips")), .safe)
    }

    func testRetiredFolderItselfIsNotAnItem() async throws {
        let f = try FixtureHome()
        let d = "Library/Logs/DiagnosticReports"
        try f.file("\(d)/Retired/Cursor-1.ips", modified: ago(days: 5))
        try f.dir("\(d)/Retired", modified: ago(days: 5))
        let r = try await run(f)
        XCTAssertNil(r.item(f.abs("\(d)/Retired")))
        XCTAssertNotNil(r.item(f.abs("\(d)/Retired/Cursor-1.ips")))
    }

    // MARK: temp dirs

    func testTempDirRulesNeverMatchFreshDirs() async throws {
        let f = try FixtureHome()
        try f.dir("$TMP/claude-501", modified: ago(hours: 1))
        try f.dir("$TMP/claude-502", modified: ago(hours: 23))
        try f.file("$TMP/claude-503/old.txt", modified: ago(hours: 30))
        try f.dir("$TMP/claude-503", modified: ago(hours: 25))
        let r = try await run(f, over: tempOverride(f))
        XCTAssertEqual(r.tier(f.abs("$TMP/claude-501")), .keep)
        XCTAssertEqual(r.tier(f.abs("$TMP/claude-502")), .keep)
        XCTAssertEqual(r.tier(f.abs("$TMP/claude-503")), .review)
        let temp = r.items.filter { $0.ruleID == "system.agent-temp" }
        XCTAssertEqual(temp.count, 3)
        for i in temp {
            if let m = i.lastModified, m > now.addingTimeInterval(-86_400) { XCTAssertEqual(i.tier, .keep, i.path) }
        }
    }

    func testTempDirFreshChildMakesWholeDirKeep() async throws {
        let f = try FixtureHome()
        try f.file("$TMP/claude-503/new.txt", modified: ago(hours: 5.0 / 60))
        try f.dir("$TMP/claude-503", modified: ago(days: 3))
        let r = try await run(f, over: tempOverride(f))
        XCTAssertEqual(r.tier(f.abs("$TMP/claude-503")), .keep)
    }

    func testTempRulesIgnoreNonAgentDirs() async throws {
        let f = try FixtureHome()
        try f.dir("$TMP/TemporaryDirectory.abc", modified: ago(days: 5))
        try f.dir("$TMP/com.apple.x", modified: ago(days: 5))
        try f.dir("$TMP/privtmp/claude-9", modified: ago(days: 5))
        let r = try await run(f, over: tempOverride(f))
        XCTAssertNil(r.item(f.abs("$TMP/TemporaryDirectory.abc")))
        XCTAssertNil(r.item(f.abs("$TMP/com.apple.x")))
        XCTAssertEqual(r.tier(f.abs("$TMP/privtmp/claude-9")), .review)
    }

    func testOtherUsersTempDirsSkipped() async throws {
        let f = try FixtureHome()
        try f.dir("$TMP/claude-501", modified: ago(days: 5))
        let r = try await run(f, over: tempOverride(f), userID: getuid() + 1)
        XCTAssertTrue(r.items.filter { $0.ruleID == "system.agent-temp" }.isEmpty)
    }

    // MARK: logs and caches

    func testAiLogsKeepWhenFresh() async throws {
        let f = try FixtureHome()
        try f.file("Library/Logs/Claude/main.log", modified: ago(hours: 1))
        try f.file("Library/Logs/Claude/old.log", modified: ago(days: 3))
        let r = try await run(f)
        XCTAssertEqual(r.tier(f.abs("Library/Logs/Claude/main.log")), .keep)
        XCTAssertEqual(r.tier(f.abs("Library/Logs/Claude/old.log")), .safe)
        XCTAssertNil(r.item(f.abs("Library/Logs/Claude")))
    }

    func testAppCachesGlobsAndQuit() async throws {
        let f = try FixtureHome()
        let c = "Library/Caches"
        try f.file("\(c)/com.anthropic.claudefordesktop/x", modified: ago(days: 3))
        try f.dir("\(c)/com.anthropic.claudefordesktop", modified: ago(days: 3))
        try f.file("\(c)/com.anthropic.claudefordesktop.ShipIt/x", modified: ago(hours: 1))
        try f.dir("\(c)/com.anthropic.claudefordesktop.ShipIt", modified: ago(hours: 1))
        try f.file("\(c)/dev.kiro.desktop.ShipIt/x", modified: ago(days: 3))
        try f.dir("\(c)/dev.kiro.desktop.ShipIt", modified: ago(days: 3))
        try f.dir("\(c)/com.todesktop.otherapp", modified: ago(days: 3))
        try f.dir("\(c)/claude-cli-nodejs", modified: ago(days: 3))
        let r = try await run(f)
        let main = r.item(f.abs("\(c)/com.anthropic.claudefordesktop"))
        XCTAssertEqual(main?.tier, .safe)
        XCTAssertEqual(main?.ruleID, "system.app-cache.claude")
        XCTAssertEqual(main?.requiresAppQuit, "com.anthropic.claudefordesktop")
        XCTAssertEqual(r.tier(f.abs("\(c)/com.anthropic.claudefordesktop.ShipIt")), .keep)
        XCTAssertEqual(r.tier(f.abs("\(c)/dev.kiro.desktop.ShipIt")), .safe)
        XCTAssertNil(r.item(f.abs("\(c)/com.todesktop.otherapp")))
        XCTAssertNil(r.item(f.abs("\(c)/claude-cli-nodejs")))
    }

    func testPackageCachesReviewAndEnvOverride() async throws {
        let f = try FixtureHome()
        let defaults = [".npm/_cacache", "Library/Caches/pnpm", ".cache/uv", "Library/Caches/pip", ".bun/install/cache"]
        for p in defaults { try f.file("\(p)/x", bytes: 10, modified: ago(days: 1)) }
        try f.file(".cache/huggingface/x", modified: ago(days: 9))
        let r = try await run(f)
        for p in defaults { XCTAssertEqual(r.tier(f.abs(p)), .review, p) }
        XCTAssertNil(r.item(f.abs(".cache/huggingface")))

        // UV_CACHE_DIR override: FixtureHome.env is a let, so use overridePaths-free expansion of the loaded rule.
        let g = try FixtureHome()
        var env = g.env
        env.variables["UV_CACHE_DIR"] = g.abs("uvc")
        let loaded = RuleLoader(environment: env, bundledRulesDirectory: CoreResources.rulesDirectoryURL,
                                userRulesDirectory: nil, guardFactory: ScanGuard.loaderFactory(environment: env)).load()
        let uv = try XCTUnwrap(loaded.allRules.first { $0.rule.id == "system.uv-cache" })
        XCTAssertEqual(uv.expandedPaths, [g.abs("uvc")])
        XCTAssertFalse(uv.expandedPaths.contains(g.abs(".cache/uv")))
    }

    // MARK: file-level

    func testEveryExplanationStatesRegenerability() throws {
        let url = try XCTUnwrap(CoreResources.rulesDirectoryURL?.appendingPathComponent(file))
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let rules = try XCTUnwrap(json?["rules"] as? [[String: Any]])
        XCTAssertFalse(rules.isEmpty)
        for rule in rules {
            let e = try XCTUnwrap(rule["explanation"] as? String)
            XCTAssertTrue(e.hasPrefix("Regenerable:") || e.hasPrefix("Not regenerable:"), "\(rule["id"] ?? "?")")
            XCTAssertTrue((rule["id"] as? String ?? "").hasPrefix("system."))
        }
    }

    func testAbsentEverythingProducesNothing() async throws {
        let f = try FixtureHome()
        let r = try await run(f, over: tempOverride(f))
        XCTAssertEqual(r.items.count, 0)
        XCTAssertEqual(r.warnings.count, 0)
        XCTAssertEqual(r.loadErrors, [])
    }

    func testFileLoadsWithRealGuard() throws {
        let f = try FixtureHome()
        let result = RuleHarness.loadAllBundled(fixture: f)
        XCTAssertEqual(result.errors, [], result.errors.map(\.description).joined(separator: "\n"))
        XCTAssertTrue(result.allRules.contains { $0.rule.id == "system.ai-logs" })
        XCTAssertTrue(result.allRules.allSatisfy { $0.tool.rawValue != "system" || $0.rule.id.hasPrefix("system.") })
    }

    func testReadOnly() async throws {
        let f = try FixtureHome()
        try f.file("Library/Logs/Claude/old.log", modified: ago(days: 3))
        try f.file("Library/Logs/DiagnosticReports/Cursor-1.ips", modified: ago(days: 3))
        try f.file("$TMP/claude-501/a", modified: ago(days: 3))
        try f.file(".npm/_cacache/x", modified: ago(days: 3))
        let before = try f.snapshot()
        _ = try await run(f, over: tempOverride(f))
        XCTAssertEqual(try f.snapshot(), before)
    }
}
