import XCTest
@testable import DiskKeeperCore

/// T23: user rule files (temp dirs, fake guard). Bundled rules always win and always load.
final class UserRulesLoadTests: XCTestCase {
    private var tmp: TemporaryDirectory!
    private var env: PathEnvironment!

    override func setUpWithError() throws {
        tmp = try TemporaryDirectory()
        env = RuleFixtures.environment(tmp)
    }
    override func tearDown() { tmp = nil }

    private func write(_ dir: String, _ name: String, _ content: String) throws {
        try tmp.file("\(dir)/\(name)", contents: Data(content.utf8))
    }

    private func load() -> RuleLoadResult {
        RuleFixtures.loader(env, bundled: tmp.url.appendingPathComponent("bundled"),
                            user: tmp.url.appendingPathComponent("user")).load()
    }

    private func bundledOK() throws {
        try write("bundled", "b.json", RuleFixtures.file(tool: "b", rules: [RuleFixtures.rule(id: "b.r", paths: #"["~/.b/cache"]"#)]))
    }

    func testInvalidUserFileKeepsBundledAndReportsFileAndPath() throws {
        try bundledOK()
        try write("user", "bad.json", #"{"schemaVersion":1,"tool":{"id":"u","name":"U"},"rules":[],"x":1}"#)
        let r = load()
        XCTAssertEqual(r.allRules.map(\.rule.id), ["b.r"])
        XCTAssertEqual(r.errors.count, 1)
        XCTAssertEqual(r.errors[0].file?.lastPathComponent, "bad.json")
        XCTAssertEqual(r.errors[0].source, .user)
    }

    func testUserRuleTargetingProtectedPathsLosesThePath() throws {
        for target in ["~/.ssh", "~/.claude.json"] {
            try? FileManager.default.removeItem(at: tmp.url.appendingPathComponent("user"))
            try write("user", "evil.json", RuleFixtures.file(tool: "u", rules: [RuleFixtures.rule(id: "u.r", paths: #"["\#(target)"]"#, tier: "review")]))
            let r = load()
            XCTAssertEqual(r.allRules.first?.expandedPaths, [], target)
            XCTAssertEqual(r.warnings.map(\.kind), [.protectedPathTarget], target)
        }
    }

    func testUserRuleOutsideAllowedRootsRejected() throws {
        try write("user", "out.json", RuleFixtures.file(tool: "u", rules: [RuleFixtures.rule(id: "u.r", paths: #"["/private/etc/x"]"#)]))
        let r = load()
        XCTAssertTrue(r.allRules.isEmpty)
        XCTAssertEqual(r.errors.count, 1)
    }

    func testDuplicateIDBundledWins() throws {
        try bundledOK()
        try write("user", "dup.json", RuleFixtures.file(tool: "b", rules: [RuleFixtures.rule(id: "b.r", paths: #"["~/.b/other"]"#)]))
        let r = load()
        XCTAssertEqual(r.ruleSets.map(\.source), [.bundled])
        XCTAssertEqual(r.errors.map(\.kind), [.duplicateRuleID])
    }

    func testUserSafeIsCappedAtReviewWithWarning() throws {
        try write("user", "u.json", RuleFixtures.file(tool: "u", rules: [RuleFixtures.rule(id: "u.r", tier: "safe")]))
        let r = load()
        XCTAssertEqual(r.allRules.first?.rule.tier, .review)
        XCTAssertEqual(r.warnings.map(\.kind), [.userTierCapped])
        XCTAssertTrue(r.warnings[0].message.contains("Safe is not allowed in user rules"))
        XCTAssertEqual(r.warnings[0].file?.lastPathComponent, "u.json")
    }

    func testUserTierWhenSafeIsCappedAndKeepStaysKeep() throws {
        let extra = #""tierWhen": [{"if": {"olderThanDays": 30}, "tier": "safe"}, {"if": {"newerThanDays": 1}, "tier": "keep"}]"#
        try write("user", "u.json", RuleFixtures.file(tool: "u", rules: [RuleFixtures.rule(id: "u.r", tier: "review", extra: extra)]))
        let rule = load().allRules[0].rule
        XCTAssertEqual(rule.tier, .review)
        XCTAssertEqual(rule.tierWhen.map(\.tier), [.review, .keep])
        // Evaluated on a 100-day-old item: the capped entry gives Review, never Safe.
        let facts = ItemFacts(lastModified: Date(timeIntervalSinceNow: -100 * 86_400))
        XCTAssertEqual(TierEvaluator.evaluate(rule, facts: facts, now: Date()).tier, .review)
    }

    func testBundledSafeIsNotCapped() throws {
        try bundledOK()
        let r = load()
        XCTAssertEqual(r.allRules[0].rule.tier, .safe)
        XCTAssertTrue(r.warnings.isEmpty)
    }

    func testUserReviewOrKeepRulesProduceNoCapWarning() throws {
        try write("user", "u.json", RuleFixtures.file(tool: "u", rules: [RuleFixtures.rule(id: "u.r", tier: "keep")]))
        let r = load()
        XCTAssertEqual(r.allRules[0].rule.tier, .keep)
        XCTAssertTrue(r.warnings.isEmpty)
    }

    func testUserIDOutsideToolPrefixAndReservedToolNamespaceRejected() throws {
        try write("user", "a.json", RuleFixtures.file(tool: "u", rules: [RuleFixtures.rule(id: "other.r")]))
        XCTAssertEqual(load().errors.map(\.kind), [.invalidRuleID])
        try FileManager.default.removeItem(at: tmp.url.appendingPathComponent("user"))
        try write("user", "b.json", RuleFixtures.file(tool: "tool", rules: [RuleFixtures.rule(id: "tool.docker.x")]))
        XCTAssertEqual(load().errors.map(\.kind), [.invalidRuleID])
    }

    func testUserToolCommandItemIsRefusedByTheRegistry() {
        // Only built-in scanners (the reserved `tool.` rule-id namespace) may run a command; a user rule never does.
        let item = ScanItem(url: URL(fileURLWithPath: env.home + "/.u/x"), displayName: "x", tool: "u", category: .aiToolData,
                            sizeAllocated: 1, sizeLogical: 1, fileCount: 1, lastModified: nil, tier: .review,
                            explanation: "x", ruleID: "u.r", cleanupMethod: .toolCommand(command: "rm", arguments: ["-rf", "/"]))
        guard case .failure = ToolCommandRegistry.builtIn.match(item, environment: env) else { return XCTFail("must be refused") }
    }

    // F11: wildcard-ish and container protects are rejected for user files too.
    func testUserProtectFoldCasesRejected() throws {
        for pattern in ["~/library/**", "$APP_SUPPORT/[a-z]*"] {
            try? FileManager.default.removeItem(at: tmp.url.appendingPathComponent("user"))
            try write("user", "p.json", RuleFixtures.file(tool: "u", protect: #"["\#(pattern)"]"#, rules: [RuleFixtures.rule(id: "u.r")]))
            let r = load()
            XCTAssertEqual(r.errors.map(\.kind), [.invalidProtectPattern], pattern)
            XCTAssertTrue(r.allRules.isEmpty, pattern)
        }
    }

    func testUserProtectNeverSubtracts() throws {
        try write("user", "p.json", RuleFixtures.file(tool: "u", protect: #"["~/.u/keep/**"]"#, rules: [RuleFixtures.rule(id: "u.r")]))
        let r = load()
        XCTAssertEqual(r.protectPatterns, [env.home + "/.u/keep/**"])
    }
}
