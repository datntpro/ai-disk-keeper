import XCTest
@testable import DiskKeeperCore

struct HarnessResult {
    let items: [ScanItem]
    let warnings: [ScanWarning]
    let loadErrors: [RuleLoadError]

    func item(_ abs: String) -> ScanItem? { items.first { $0.path == abs } }
    func tier(_ abs: String) -> RiskTier? { item(abs)?.tier }
    var paths: Set<String> { Set(items.map(\.path)) }
}

private actor HarnessCollector {
    var items: [ScanItem] = []
    var warnings: [ScanWarning] = []
    func add(_ i: ScanItem) { items.append(i) }
    func add(_ w: ScanWarning) { warnings.append(w) }
}

enum RuleHarness {
    /// Copies ONLY `bundledFile` (e.g. "claude-code.json") from the bundled rules into a fresh rules dir,
    /// loads it with the REAL guard (`ScanGuard.loaderFactory`) and runs `RuleScanner`.
    /// `overridePaths[ruleID]` replaces that rule's expandedPaths (for literal roots such as /private/tmp,
    /// which tests must never read). Fails the test if the file is missing from the bundle.
    static func run(bundledFile: String, fixture: FixtureHome, now: Date = Date(),
                    overridePaths: [String: [String]] = [:], userID: uid_t = getuid()) async throws -> HarnessResult {
        guard let source = CoreResources.rulesDirectoryURL?.appendingPathComponent(bundledFile),
              let data = FileManager.default.contents(atPath: source.path) else {
            XCTFail("bundled rule file \(bundledFile) is missing from the resource bundle")
            return HarnessResult(items: [], warnings: [], loadErrors: [])
        }
        return try await execute(data: data, name: bundledFile, fixture: fixture, now: now,
                                 overridePaths: overridePaths, userID: userID)
    }

    /// Same over an inline JSON string.
    static func run(json: String, fixture: FixtureHome, now: Date = Date(),
                    overridePaths: [String: [String]] = [:], userID: uid_t = getuid()) async throws -> HarnessResult {
        try await execute(data: Data(json.utf8), name: "inline.json", fixture: fixture, now: now,
                          overridePaths: overridePaths, userID: userID)
    }

    /// Loads ALL bundled files against `fixture.env` with the real guard; returns the load result.
    static func loadAllBundled(fixture: FixtureHome) -> RuleLoadResult {
        RuleLoader(environment: fixture.env, bundledRulesDirectory: CoreResources.rulesDirectoryURL,
                   userRulesDirectory: nil, guardFactory: ScanGuard.loaderFactory(environment: fixture.env)).load()
    }

    /// Loads inline rule JSON against the fixture with the real guard (no scan). For tests that drive
    /// `CandidateExpander` or a hand-configured `RuleScanner` directly.
    static func loadRules(json: String, fixture: FixtureHome) throws -> RuleLoadResult {
        let rulesDir = try TemporaryDirectory()
        try rulesDir.file("inline.json", contents: Data(json.utf8))
        return RuleLoader(
            environment: fixture.env, bundledRulesDirectory: rulesDir.url, userRulesDirectory: nil,
            guardFactory: ScanGuard.loaderFactory(environment: fixture.env)).load()
    }

    static func context(_ fixture: FixtureHome, loaded: RuleLoadResult, now: Date = Date(), userID: uid_t = getuid(),
                        sizerOptions: FileSizer.Options = .init(), maxConcurrentSizing: Int = 4) throws -> ScanContext {
        ScanContext(environment: fixture.env,
                    pathGuard: try ScanGuard(environment: fixture.env, protectPatterns: loaded.protectPatterns),
                    now: now, userID: userID, sizerOptions: sizerOptions, maxConcurrentSizing: maxConcurrentSizing)
    }

    private static func execute(data: Data, name: String, fixture: FixtureHome, now: Date,
                                overridePaths: [String: [String]], userID: uid_t) async throws -> HarnessResult {
        let rulesDir = try TemporaryDirectory()   // outside the fixture, so snapshots are unaffected
        try rulesDir.file(name, contents: data)
        let loaded = RuleLoader(
            environment: fixture.env, bundledRulesDirectory: rulesDir.url, userRulesDirectory: nil,
            guardFactory: ScanGuard.loaderFactory(environment: fixture.env)).load()

        let fixtureRoot = PathCanonicalizer.key(fixture.tmp.url.path).components
        for (id, paths) in overridePaths {
            for p in paths {
                let key = PathCanonicalizer.key(p).components
                let inside = PathNormalization.isAbsolute(p) && !PathNormalization.containsParentReference(p)
                    && key.count > fixtureRoot.count && Array(key.prefix(fixtureRoot.count)) == fixtureRoot
                if !inside {
                    XCTFail("override path \(p) for \(id) is outside the fixture; not scanning")
                    return HarnessResult(items: [], warnings: [], loadErrors: loaded.errors)
                }
            }
        }
        let rules = loaded.allRules.map { r -> ResolvedRule in
            guard let paths = overridePaths[r.rule.id] else { return r }
            return ResolvedRule(rule: r.rule, tool: r.tool, expandedPaths: paths, unavailablePaths: r.unavailablePaths)
        }

        let pathGuard = try ScanGuard(environment: fixture.env, protectPatterns: loaded.protectPatterns)
        let context = ScanContext(environment: fixture.env, pathGuard: pathGuard, now: now, userID: userID)
        let collector = HarnessCollector()
        let sink = ScanSink(item: { await collector.add($0) }, warning: { await collector.add($0) },
                            progress: { _ in })
        try await RuleScanner(rules: rules).scan(context: context, sink: sink)
        return HarnessResult(items: await collector.items.sorted { $0.path < $1.path },
                             warnings: await collector.warnings, loadErrors: loaded.errors)
    }
}
