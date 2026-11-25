import XCTest
@testable import DiskKeeperCore

final class ClaudeCodeRulesTests: XCTestCase {
    private var fixture: FixtureHome!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws { fixture = try FixtureHome() }
    override func tearDown() { fixture = nil }

    private func days(_ d: Double) -> Date { now.addingTimeInterval(-d * 86_400) }
    private func run() async throws -> HarnessResult {
        try await RuleHarness.run(bundledFile: "claude-code.json", fixture: fixture, now: now)
    }

    // MARK: transcripts

    func testTranscriptTiersByAge() async throws {
        try fixture.file(".claude/projects/p/a.jsonl", modified: days(2))
        try fixture.file(".claude/projects/p/b.jsonl", modified: days(10))
        try fixture.file(".claude/projects/p/c.jsonl", modified: days(40))
        let r = try await run()
        XCTAssertEqual(r.tier(fixture.abs(".claude/projects/p/a.jsonl")), .keep)
        XCTAssertEqual(r.tier(fixture.abs(".claude/projects/p/b.jsonl")), .review)
        XCTAssertEqual(r.tier(fixture.abs(".claude/projects/p/c.jsonl")), .safe)
    }

    func testTranscriptBoundaryDays() async throws {
        try fixture.file(".claude/projects/p/a.jsonl", modified: days(7))
        try fixture.file(".claude/projects/p/b.jsonl", modified: days(30))
        let r = try await run()
        XCTAssertEqual(r.tier(fixture.abs(".claude/projects/p/a.jsonl")), .review)
        XCTAssertEqual(r.tier(fixture.abs(".claude/projects/p/b.jsonl")), .review)
    }

    func testTranscriptProjectFromCwd() async throws {
        let p = try fixture.file(".claude/projects/-Users-me-src-app/s.jsonl", modified: days(10))
        try Data(#"{"cwd":"/Users/me/src/app","type":"user"}"#.utf8 + [0x0A]).write(to: URL(fileURLWithPath: p))
        try FileManager.default.setAttributes([.modificationDate: days(10)], ofItemAtPath: p)
        let r = try await run()
        let item = try XCTUnwrap(r.item(p))
        XCTAssertEqual(item.project?.id, "/Users/me/src/app")
        XCTAssertEqual(item.project?.displayName, "app")
    }

    func testTranscriptProjectFallbackName() async throws {
        let p = try fixture.file(".claude/projects/-Users-me-src-app/s.jsonl", modified: days(10))
        let r = try await run()
        XCTAssertEqual(r.item(p)?.project?.id, "name:-Users-me-src-app")
    }

    // MARK: session data / memory

    func testSessionDataDirsAreItemsMemoryIsNot() async throws {
        try fixture.file(".claude/projects/p/u1/tool-results/x", modified: days(40))
        try fixture.dir(".claude/projects/p/u1", modified: days(40))
        try fixture.file(".claude/projects/p/memory/MEMORY.md", modified: days(40))
        try fixture.file(".claude/projects/p/u1.jsonl", modified: days(40))
        let r = try await run()
        XCTAssertEqual(r.paths, [fixture.abs(".claude/projects/p/u1"), fixture.abs(".claude/projects/p/u1.jsonl")])
        XCTAssertFalse(r.paths.contains { $0.contains("/memory") })
    }

    func testMemoryNeverAnItemEvenWithoutExclude() async throws {
        try fixture.file(".claude/projects/p/u1/x", modified: days(40))
        try fixture.file(".claude/projects/p/memory/MEMORY.md", modified: days(40))
        let url = try XCTUnwrap(CoreResources.rulesDirectoryURL).appendingPathComponent("claude-code.json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var rules = try XCTUnwrap(json["rules"] as? [[String: Any]])
        for i in rules.indices where rules[i]["id"] as? String == "claude-code.session-data" {
            var m = try XCTUnwrap(rules[i]["match"] as? [String: Any])
            m["exclude"] = nil
            rules[i]["match"] = m
        }
        json["rules"] = rules
        let text = String(decoding: try JSONSerialization.data(withJSONObject: json), as: UTF8.self)
        let r = try await RuleHarness.run(json: text, fixture: fixture, now: now)
        XCTAssertEqual(r.loadErrors, [])
        XCTAssertTrue(r.paths.contains(fixture.abs(".claude/projects/p/u1")))
        XCTAssertFalse(r.paths.contains { $0.contains("/memory") })
    }

    func testProjectDirIsNeverAnItem() async throws {
        try fixture.file(".claude/projects/p/a.jsonl", modified: days(40))
        try fixture.file(".claude/projects/p/memory/m.md")
        try fixture.file(".claude/projects/p/u/x")
        let r = try await run()
        XCTAssertFalse(r.paths.contains(fixture.abs(".claude/projects/p")))
        XCTAssertFalse(r.paths.contains(fixture.abs(".claude/projects")))
    }

    // MARK: per-session dirs

    func testPerSessionDirsKeepWhenFresh() async throws {
        let names = ["todos", "shell-snapshots", "session-env", "paste-cache", "debug"]
        for n in names {
            try fixture.file(".claude/\(n)/fresh.json", modified: now.addingTimeInterval(-3600))
            try fixture.file(".claude/\(n)/old.json", modified: days(3))
        }
        let r = try await run()
        for n in names {
            XCTAssertEqual(r.tier(fixture.abs(".claude/\(n)/fresh.json")), .keep, n)
            XCTAssertEqual(r.tier(fixture.abs(".claude/\(n)/old.json")), .safe, n)
        }
    }

    func testFileHistoryAndBackupsTiers() async throws {
        for (n, d) in [("a", 2.0), ("b", 10.0), ("c", 40.0)] {
            let dir = ".claude/file-history/\(n)"
            try fixture.file(dir + "/f", modified: days(d))
            try fixture.dir(dir, modified: days(d))
        }
        try fixture.file(".claude/backups/new.json", modified: days(2))
        try fixture.file(".claude/backups/old.json", modified: days(40))
        let r = try await run()
        XCTAssertEqual(r.tier(fixture.abs(".claude/file-history/a")), .keep)
        XCTAssertEqual(r.tier(fixture.abs(".claude/file-history/b")), .review)
        XCTAssertEqual(r.tier(fixture.abs(".claude/file-history/c")), .safe)
        XCTAssertEqual(r.tier(fixture.abs(".claude/backups/new.json")), .keep)
        XCTAssertEqual(r.tier(fixture.abs(".claude/backups/old.json")), .review)
    }

    func testCacheAndMcpLogsSafe() async throws {
        try fixture.file(".claude/cache/changelog.md", modified: now)
        try fixture.file("Library/Caches/claude-cli-nodejs/p/mcp.log", modified: now)
        try fixture.file(".claude/plugins/cache/x/y", modified: days(1))
        try fixture.file(".cache/claude/staging/x", modified: days(3))
        let r = try await run()
        XCTAssertEqual(r.tier(fixture.abs(".claude/cache")), .safe)
        XCTAssertEqual(r.tier(fixture.abs("Library/Caches/claude-cli-nodejs")), .safe)
        XCTAssertEqual(r.tier(fixture.abs(".claude/plugins/cache")), .review)
        XCTAssertEqual(r.tier(fixture.abs(".cache/claude")), .safe)
    }

    func testLegacyTranscriptsTiers() async throws {
        try fixture.file(".claude/transcripts/a.jsonl", modified: days(2))
        try fixture.file(".claude/transcripts/b.jsonl", modified: days(40))
        let r = try await run()
        XCTAssertEqual(r.tier(fixture.abs(".claude/transcripts/a.jsonl")), .keep)
        XCTAssertEqual(r.tier(fixture.abs(".claude/transcripts/b.jsonl")), .safe)
    }

    func testPluginMarketplacesNeverAnItem() async throws {
        try fixture.file(".claude/plugins/marketplaces/m/x", modified: days(100))
        try fixture.file(".claude/plans/p.md", modified: days(100))
        try fixture.file(".claude/history.jsonl", modified: days(100))
        let r = try await run()
        XCTAssertTrue(r.items.isEmpty)
    }

    // MARK: CLAUDE_CONFIG_DIR

    private func altRun(_ alt: String) async throws -> (HarnessResult, PathEnvironment, RuleLoadResult) {
        let env = PathEnvironment(home: fixture.home, temporaryDirectory: fixture.tempDir,
                                  variables: ["CLAUDE_CONFIG_DIR": alt])
        let source = try XCTUnwrap(CoreResources.rulesDirectoryURL).appendingPathComponent("claude-code.json")
        let dir = try TemporaryDirectory()
        try dir.file("claude-code.json", contents: try Data(contentsOf: source))
        let loaded = RuleLoader(environment: env, bundledRulesDirectory: dir.url, userRulesDirectory: nil,
                                guardFactory: ScanGuard.loaderFactory(environment: env)).load()
        let guardian = try ScanGuard(environment: env, protectPatterns: loaded.protectPatterns)
        let ctx = ScanContext(environment: env, pathGuard: guardian, now: now, userID: getuid())
        let box = Collector()
        let sink = ScanSink(item: { await box.add($0) }, warning: { await box.add($0) }, progress: { _ in })
        try await RuleScanner(rules: loaded.allRules).scan(context: ctx, sink: sink)
        let res = HarnessResult(items: await box.items, warnings: await box.warnings, loadErrors: loaded.errors)
        return (res, env, loaded)
    }

    private actor Collector {
        var items: [ScanItem] = []
        var warnings: [ScanWarning] = []
        func add(_ i: ScanItem) { items.append(i) }
        func add(_ w: ScanWarning) { warnings.append(w) }
    }

    func testClaudeConfigDirEnvRedirectsAllPaths() async throws {
        let alt = fixture.abs("alt")
        try fixture.file("alt/projects/p/a.jsonl", modified: days(40))
        try fixture.file("alt/todos/t.json", modified: days(5))
        try fixture.file(".claude/projects/p/a.jsonl", modified: days(40))
        try fixture.file(".claude/todos/t.json", modified: days(5))
        let (r, _, _) = try await altRun(alt)
        XCTAssertEqual(r.loadErrors, [])
        XCTAssertEqual(r.paths, [alt + "/projects/p/a.jsonl", alt + "/todos/t.json"])
        XCTAssertFalse(r.paths.contains { $0.contains("/.claude/") })
    }

    func testProtectTemplatesCoverConfigDir() async throws {
        let alt = fixture.abs("alt")
        let (_, env, loaded) = try await altRun(alt)
        let g = try ScanGuard(environment: env, protectPatterns: loaded.protectPatterns)
        for p in ["settings.json", ".credentials.json", "skills/x", "plans/p.md", "projects/p/memory/m.md",
                  "history.jsonl", "CLAUDE.md", "agents/a.md", "commands/c.md", "hooks/h.sh", "keybindings.json",
                  "output-styles/o.md", "plugins/config.json", "plugins/installed_plugins.json"] {
            if case .allowed = g.check(alt + "/" + p) { XCTFail("\(p) must be protected") }
        }
    }

    // MARK: denylist

    func testNoRuleTargetsDenylist() async throws {
        var created: [String] = []
        for pat in ProtectedPaths.builtInAnchored {
            var t = pat.template
            if t.hasPrefix("~/") { t = String(t.dropFirst(2)) }
            else if t.hasPrefix("$APP_SUPPORT/") { t = "Library/Application Support/" + t.dropFirst(13) }
            else { continue }
            t = t.replacingOccurrences(of: "*", with: "x")
            try fixture.file(t, modified: days(100))
            created.append(fixture.abs(t))
        }
        for b in ProtectedPaths.builtInBasenames {
            let name = b.template.replacingOccurrences(of: "*", with: "x")
            let rel = ".claude/projects/p/" + name
            try fixture.file(rel, modified: days(100))
            created.append(fixture.abs(rel))
        }
        let r = try await run()
        let protectedKeys = created.map { PathCanonicalizer.key($0).components }
        for item in r.items {
            let k = PathCanonicalizer.key(item.path).components
            for p in protectedKeys {
                XCTAssertFalse(k.count >= p.count && Array(k.prefix(p.count)) == p,
                               "\(item.path) is at or inside protected \(p.joined(separator: "/"))")
            }
        }
    }

    // MARK: misc

    func testAbsentToolProducesNothing() async throws {
        let r = try await run()
        XCTAssertTrue(r.items.isEmpty && r.warnings.isEmpty && r.loadErrors.isEmpty)
    }

    func testFileLoadsWithRealGuard() async throws {
        let r = try await run()
        XCTAssertTrue(r.loadErrors.isEmpty)
        let loaded = RuleHarness.loadAllBundled(fixture: fixture)
        let mine = loaded.allRules.filter { $0.tool.rawValue == "claude-code" }
        XCTAssertEqual(mine.count, 14)
        XCTAssertTrue(mine.allSatisfy { $0.rule.id.hasPrefix("claude-code.") })
    }

    func testReadOnly() async throws {
        try fixture.file(".claude/projects/p/a.jsonl", modified: days(40))
        try fixture.file(".claude/todos/t.json", modified: days(5))
        try fixture.file(".claude/projects/p/memory/m.md")
        let before = try fixture.snapshot()
        _ = try await run()
        XCTAssertEqual(try fixture.snapshot(), before)
    }
}
