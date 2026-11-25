import XCTest
@testable import DiskKeeperCore

private actor OtherToolCollector {
    var items: [ScanItem] = []
    var warnings: [ScanWarning] = []
    func add(_ i: ScanItem) { items.append(i) }
    func add(_ w: ScanWarning) { warnings.append(w) }
}

/// Shared helpers for the T07 bundled-rule tests (Cursor, Codex, Gemini, Kiro, Windsurf, Copilot, Aider,
/// Continue, Orca). Everything runs against a `FixtureHome`; nothing reads the real home.
enum OtherToolRules {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let appSupport = "Library/Application Support"

    static func days(_ d: Double) -> Date { now.addingTimeInterval(-d * 86_400) }

    struct Run {
        let fixture: FixtureHome
        let loaded: RuleLoadResult
        let items: [ScanItem]
        let warnings: [ScanWarning]
        let pathGuard: ScanGuard

        func item(_ rel: String) -> ScanItem? { items.first { $0.path == fixture.abs(rel) } }
        func tier(_ rel: String) -> RiskTier? { item(rel)?.tier }
        /// (relative path, tier) pairs, sorted by path.
        var pairs: [String] {
            items.map { "\($0.path.dropFirst(fixture.home.count + 1)):\($0.tier.rawValue)" }.sorted()
        }
        var errors: [RuleLoadError] { loaded.errors }
    }

    /// Loads ONLY `file` from the bundle with the real guard and scans the fixture.
    static func run(_ file: String, _ fixture: FixtureHome, variables: [String: String] = [:]) async throws -> Run {
        guard let source = CoreResources.rulesDirectoryURL?.appendingPathComponent(file),
              let data = FileManager.default.contents(atPath: source.path) else {
            XCTFail("bundled rule file \(file) is missing from the resource bundle")
            throw CocoaError(.fileNoSuchFile)
        }
        let env = PathEnvironment(home: fixture.home, temporaryDirectory: fixture.tempDir, variables: variables)
        let dir = try TemporaryDirectory()
        try dir.file(file, contents: data)
        let loaded = RuleLoader(environment: env, bundledRulesDirectory: dir.url, userRulesDirectory: nil,
                                guardFactory: ScanGuard.loaderFactory(environment: env)).load()
        let pathGuard = try ScanGuard(environment: env, protectPatterns: loaded.protectPatterns)
        let context = ScanContext(environment: env, pathGuard: pathGuard, now: now, userID: getuid())
        let box = OtherToolCollector()
        let sink = ScanSink(item: { await box.add($0) }, warning: { await box.add($0) }, progress: { _ in })
        try await RuleScanner(rules: loaded.allRules).scan(context: context, sink: sink)
        return Run(fixture: fixture, loaded: loaded, items: await box.items.sorted { $0.path < $1.path },
                   warnings: await box.warnings, pathGuard: pathGuard)
    }

    /// An empty home yields nothing: no items, warnings or load errors.
    static func assertAbsent(_ file: String, line: UInt = #line) async throws {
        let r = try await run(file, try FixtureHome())
        XCTAssertTrue(r.items.isEmpty, "\(r.pairs)", line: line)
        XCTAssertTrue(r.warnings.isEmpty, "\(r.warnings)", line: line)
        XCTAssertTrue(r.errors.isEmpty, "\(r.errors)", line: line)
    }

    /// Loads with the real guard; ids carry the tool prefix; docs is https; rule paths never reach into
    /// the T18/T14 territories.
    static func assertLoads(_ file: String, tool: String, line: UInt = #line) throws {
        let fixture = try FixtureHome()
        let env = fixture.env
        guard let source = CoreResources.rulesDirectoryURL?.appendingPathComponent(file),
              let data = FileManager.default.contents(atPath: source.path) else {
            return XCTFail("missing \(file)", line: line)
        }
        let dir = try TemporaryDirectory()
        try dir.file(file, contents: data)
        let loaded = RuleLoader(environment: env, bundledRulesDirectory: dir.url, userRulesDirectory: nil,
                                guardFactory: ScanGuard.loaderFactory(environment: env)).load()
        XCTAssertEqual(loaded.errors, [], line: line)
        XCTAssertEqual(loaded.ruleSets.count, 1, line: line)
        XCTAssertEqual(loaded.ruleSets.first?.tool.id.rawValue, tool, line: line)
        let docs = loaded.ruleSets.first?.tool.docs?.absoluteString
        XCTAssertTrue(docs?.hasPrefix("https://") ?? false, "docs: \(String(describing: docs))", line: line)
        XCTAssertFalse(loaded.allRules.isEmpty, line: line)
        for r in loaded.allRules {
            XCTAssertTrue(r.rule.id.hasPrefix(tool + "."), r.rule.id, line: line)
            for t in r.rule.paths {
                let p = t.raw
                XCTAssertFalse(p.hasPrefix("$CACHES") || p.hasPrefix("$LOGS") || p.hasPrefix("$TMPDIR") || p.hasPrefix("/tmp")
                               || p.hasPrefix("/private/tmp"), "T18 territory: \(p)", line: line)
                XCTAssertFalse(p.contains("orca/workspaces"), "T14 territory: \(p)", line: line)
            }
        }
    }

    /// Creates every `files` entry (relative to the fixture home), scans, and checks that nothing at or
    /// below any of them is an item and that the guard (with the file's protect patterns) denies each.
    static func assertProtected(_ file: String, files: [String], variables: [String: String] = [:],
                                line: UInt = #line) async throws {
        let fixture = try FixtureHome()
        for f in files { try fixture.file(f) }
        let r = try await run(file, fixture, variables: variables)
        XCTAssertTrue(r.errors.isEmpty, "\(r.errors)", line: line)
        for f in files {
            let abs = fixture.abs(f)
            XCTAssertFalse(r.items.contains { $0.path == abs || $0.path.hasPrefix(abs + "/") || abs.hasPrefix($0.path + "/") },
                           "protected \(f) is (inside) an item", line: line)
            XCTAssertFalse(r.pathGuard.check(abs).isAllowed, "guard allows \(f)", line: line)
        }
    }

    /// The scan never modifies the fixture.
    static func assertReadOnly(_ file: String, populate: (FixtureHome) throws -> Void, line: UInt = #line) async throws {
        let fixture = try FixtureHome()
        try populate(fixture)
        let before = try fixture.snapshot()
        let r = try await run(file, fixture)
        XCTAssertFalse(r.items.isEmpty, "populate produced no items", line: line)
        XCTAssertEqual(try fixture.snapshot(), before, line: line)
    }

    /// A directory whose newest content is `date` old.
    static func agedDir(_ fx: FixtureHome, _ rel: String, days d: Double) throws {
        try fx.file(rel + "/data", bytes: 10, modified: days(d))
        try fx.dir(rel, modified: days(d))
    }
}
