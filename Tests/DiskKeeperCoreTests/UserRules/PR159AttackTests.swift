import Darwin
import XCTest
@testable import DiskKeeperCore

/// Verifier attack tests for PR #159 (T23). Real guard (ScanGuard.loaderFactory), fixture homes in temp dirs.
final class PR159AttackTests: XCTestCase {
    private var tmp: TemporaryDirectory!
    private var env: PathEnvironment!
    private var userDir: URL { env.userRulesDirectory }

    override func setUpWithError() throws {
        tmp = try TemporaryDirectory()
        _ = try tmp.dir("home")
        _ = try tmp.dir("tmp")
        env = PathEnvironment(home: tmp.path("home"), temporaryDirectory: tmp.path("tmp"))
        try FileManager.default.createDirectory(at: userDir, withIntermediateDirectories: true)
    }
    override func tearDown() { tmp = nil }

    private func writeUser(_ name: String, _ json: String) throws {
        try Data(json.utf8).write(to: userDir.appendingPathComponent(name))
    }
    private func load(bundled: URL? = nil) -> RuleLoadResult {
        RuleLoader(environment: env, bundledRulesDirectory: bundled, userRulesDirectory: userDir,
                   guardFactory: ScanGuard.loaderFactory(environment: env)).load()
    }
    private func ruleFile(tool: String = "u", protect: String? = nil, paths: String, match: String = #"{"kind":"self"}"#,
                          tier: String = "safe", extra: String = "") -> String {
        let p = protect.map { #""protect": \#($0),"# } ?? ""
        let x = extra.isEmpty ? "" : ", " + extra
        return #"{"schemaVersion":1,"tool":{"id":"\#(tool)","name":"U"},\#(p)"rules":[{"id":"\#(tool).r","title":"R","category":"aiToolData","paths":\#(paths),"match":\#(match),"tier":"\#(tier)","explanation":"x"\#(x)}]}"#
    }
    private func makeItem(_ url: URL, tier: RiskTier = .safe, rule: String = "u.r") throws -> ScanItem {
        let r = try FileSizer().sizeBlocking(of: url)
        return ScanItem(url: url, displayName: url.lastPathComponent, tool: "u", category: .systemJunk,
                        sizeAllocated: r.allocatedBytes, sizeLogical: r.logicalBytes, fileCount: r.fileCount,
                        lastModified: r.newestModification, tier: tier, explanation: "x", ruleID: rule)
    }
    private func oldDir(_ rel: String) throws -> URL {
        let f = try tmp.file("home/" + rel + "/blob", bytes: 10)
        let d = f.deletingLastPathComponent()
        var t = [timespec(tv_sec: 1_577_836_800, tv_nsec: 0), timespec(tv_sec: 1_577_836_800, tv_nsec: 0)]
        for p in [f.path, d.path] { _ = utimensat(AT_FDCWD, p, &t, 0) }
        return d
    }
    private func defaultEngine(user: URL?, policy: @escaping @Sendable () -> UserPolicy = { .empty }) throws -> CleanupEngine {
        try CleanupEngine.makeDefault(environment: env, bundledRulesDirectory: nil, userRulesDirectory: user,
                                      runningApps: FakeRunningApps(), inUse: FakeUsageSource([]), userPolicy: policy)
    }

    // MARK: F11 fold: user protect is honoured for case and Unicode variants

    func testUserProtectBlocksCaseVariantPath() async throws {
        try writeUser("p.json", ruleFile(protect: #"["~/Library/Caches/Foo/KeepMe/**"]"#, paths: #"["~/.u/x"]"#, tier: "review"))
        let d = try oldDir("Library/Caches/foo/keepme")   // different case on disk
        let plan = await (try defaultEngine(user: userDir)).plan([try makeItem(d)])
        XCTAssertTrue(plan.entries[0].blockers.contains { $0.code == "protectedPath" }, "\(plan.entries[0].blockers)")
    }

    func testUserProtectBlocksUnicodeVariantPath() async throws {
        let nfc = "Caf\u{00E9}", nfd = "Cafe\u{0301}"
        try writeUser("p.json", ruleFile(protect: #"["~/Library/Caches/\#(nfc)/**"]"#, paths: #"["~/.u/x"]"#, tier: "review"))
        let d = try oldDir("Library/Caches/\(nfd)/sub")
        let plan = await (try defaultEngine(user: userDir)).plan([try makeItem(d)])
        XCTAssertTrue(plan.entries[0].blockers.contains { $0.code == "protectedPath" }, "\(plan.entries[0].blockers)")
    }

    // MARK: user rule paths can't reach protected or broad targets (real guard)

    func testUserRuleCannotTargetProtectedCaseVariants() throws {
        for target in ["~/.SSH", "~/.Ssh/id_ed25519", "~/.CLAUDE.json", "~/Library/Keychains", "~/LIBRARY/keychains"] {
            try? FileManager.default.removeItem(at: userDir)
            try FileManager.default.createDirectory(at: userDir, withIntermediateDirectories: true)
            try writeUser("evil.json", ruleFile(paths: #"["\#(target)"]"#))
            let r = load()
            XCTAssertEqual(r.allRules.flatMap(\.expandedPaths), [], target)
        }
    }

    func testUserRuleBroadTargetsAreNotRemovable() throws {
        for target in ["~", "/", "~/Library", "~/Documents", "$APP_SUPPORT", "/Applications", "/System"] {
            try? FileManager.default.removeItem(at: userDir)
            try FileManager.default.createDirectory(at: userDir, withIntermediateDirectories: true)
            try writeUser("broad.json", ruleFile(paths: #"["\#(target)"]"#))
            let r = load()
            XCTAssertEqual(r.allRules.flatMap(\.expandedPaths), [], target)
        }
    }

    func testBroadUserProtectsRejected() throws {
        for pattern in ["**", "~/**", "~/*", "/**", "~/Library/**", "$APP_SUPPORT/*", "~/LIBRARY/**"] {
            try? FileManager.default.removeItem(at: userDir)
            try FileManager.default.createDirectory(at: userDir, withIntermediateDirectories: true)
            try writeUser("p.json", ruleFile(protect: #"["\#(pattern)"]"#, paths: #"["~/.u/x"]"#, tier: "review"))
            let r = load()
            XCTAssertTrue(r.protectPatterns.isEmpty, "\(pattern) accepted: \(r.protectPatterns)")
            XCTAssertFalse(r.errors.isEmpty, pattern)
            print("BROAD", pattern, r.errors.map(\.kind))
        }
    }

    // MARK: Review cap on every user path

    func testCapHoldsForKeepBaseWithSafeTierWhen() throws {
        try writeUser("u.json", ruleFile(paths: #"["~/.u/x"]"#, tier: "keep",
                                          extra: #""tierWhen":[{"if":{"olderThanDays":1},"tier":"safe"}]"#))
        let rule = load().allRules[0].rule
        XCTAssertEqual(rule.tierWhen.map(\.tier), [.review])
        let old = ItemFacts(lastModified: Date(timeIntervalSinceNow: -10 * 86_400))
        XCTAssertNotEqual(TierEvaluator.evaluate(rule, facts: old, now: Date()).tier, .safe)
    }

    func testCapHoldsThroughRealScanOfUserRule() async throws {
        _ = try oldDir(".u/x")
        try writeUser("u.json", ruleFile(paths: #"["~/.u/x"]"#, tier: "safe"))
        let engine = try ScanEngine.makeDefault(environment: env, bundledRulesDirectory: nil, userRulesDirectory: userDir)
        var items: [ScanItem] = []
        for await e in try await engine.scan() {
            if case .finished(let r) = e { items = r.items }
        }
        XCTAssertFalse(items.isEmpty, "fixture should be found")
        XCTAssertTrue(items.allSatisfy { $0.tier != .safe }, "\(items.map(\.tier))")
    }

    // MARK: hostile files fail safe, bundled untouched

    func testHostileFilesFailSafe() throws {
        // 2 MB, deep nesting, binary garbage, symlink to FIFO, symlink loop, symlink outside, dangling link.
        try Data(repeating: 0x20, count: 2 << 20).write(to: userDir.appendingPathComponent("huge.json"))
        try Data((String(repeating: "[", count: 200_000) + String(repeating: "]", count: 200_000)).utf8)
            .write(to: userDir.appendingPathComponent("deep.json"))
        try Data([0xFF, 0xFE, 0x00, 0x01]).write(to: userDir.appendingPathComponent("bin.json"))
        let fifo = tmp.path("fifo")
        XCTAssertEqual(mkfifo(fifo, 0o600), 0)
        _ = symlink(fifo, userDir.appendingPathComponent("fifo.json").path)
        _ = symlink(userDir.appendingPathComponent("loop.json").path, userDir.appendingPathComponent("loop.json").path)
        _ = symlink("/nonexistent/x.json", userDir.appendingPathComponent("dangling.json").path)
        let outside = try tmp.file("outside/evil.json", contents: Data(ruleFile(paths: #"["~/.ssh"]"#).utf8))
        _ = symlink(outside.path, userDir.appendingPathComponent("linked.json").path)
        _ = symlink(userDir.path, userDir.appendingPathComponent("dirlink.json").path)

        let bundled = try tmp.dir("bundled")
        try Data(ruleFile(tool: "b", paths: #"["~/.b/cache"]"#).utf8).write(to: bundled.appendingPathComponent("b.json"))

        let start = Date()
        let r = load(bundled: bundled)
        XCTAssertLessThan(Date().timeIntervalSince(start), 10, "loader must not hang (FIFO)")
        XCTAssertEqual(r.ruleSets.filter { $0.source == .bundled }.count, 1)
        XCTAssertEqual(r.allRules.first { $0.rule.id == "b.r" }?.rule.tier, .safe)
        XCTAssertTrue(r.errors.contains { $0.kind == .fileTooLarge })
        XCTAssertTrue(r.allRules.filter { $0.rule.id != "b.r" }.allSatisfy { $0.expandedPaths.isEmpty })
        print("HOSTILE errors:", r.errors.map { "\($0.file?.lastPathComponent ?? "-"):\($0.kind)" })
    }

    func testTooManyUserFilesCapped() throws {
        for i in 0..<230 { try writeUser(String(format: "f%03d.json", i), ruleFile(tool: "u\(i)", paths: #"["~/.u\#(i)/x"]"#, tier: "review")) }
        let r = load()
        XCTAssertTrue(r.errors.contains { $0.kind == .tooManyFiles })
        XCTAssertLessThanOrEqual(r.ruleSets.count, 200)
    }

    // MARK: overrides strictly monotone

    func testAdjusterNeverLoosensAnyCombination() async throws {
        let base = try makeItem(try oldDir(".u/y"))
        let ctx = ScanContext(environment: env, pathGuard: try ScanGuard(environment: env, protectPatterns: []))
        for t in [RiskTier.safe, .review, .keep] {
            for o in [RiskTier.safe, .review, .keep] {
                for key in [base.id, base.ruleID] {
                    var it = base; it.tier = t
                    let a = UserPolicyAdjuster(policy: UserPolicy(tierOverrides: [key: o]))
                    let out = await a.adjust([it], context: ctx).items
                    XCTAssertEqual(out.first?.tier, max(t, o), "tier \(t) override \(o) key \(key == base.id ? "item" : "rule")")
                }
            }
        }
    }

    /// Plan: "item id wins". A hand-edited rule-id Keep is defeated by an item-id Review on the same item.
    func testItemReviewOverrideBeatsRuleKeepOverride() throws {
        let it = try makeItem(try oldDir(".u/z"))
        let p = UserPolicy(tierOverrides: [it.id: .review, it.ruleID: .keep])
        XCTAssertEqual(p.effectiveTier(for: it), .review, "documented: item id wins even when the rule override is stricter")
    }

    // MARK: F1 (fixed): engines never re-read settings.json; the provider is memory-fed and fails closed

    func testUnreadableSettingsFileNeverEmptiesTheEnginePolicy() throws {
        let store = SettingsStore(environment: env)
        var s = AppSettings.defaults
        s.tierOverrides = ["item-1": .keep]
        try store.save(s)
        let provider = UserPolicyProvider(policy: s.userPolicy)
        var raw = try String(contentsOf: store.fileURL, encoding: .utf8)
        raw = raw.replacingOccurrences(of: #""schemaVersion" : \d+"#, with: #""schemaVersion" : 99"#, options: .regularExpression)
        try raw.write(to: store.fileURL, atomically: true, encoding: .utf8)
        XCTAssertEqual(provider.policy.tierOverrides, ["item-1": .keep], "the provider is not backed by the file")
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.fileURL.path), "no engine path moves the file aside")
    }

    // MARK: F3 (fixed): a protect added after the engine was built guards already-listed items

    func testProtectAddedAfterEngineBuiltIsEnforced() async throws {
        let engine = try defaultEngine(user: userDir)   // built at "launch"; folder empty
        let d = try oldDir("Library/Caches/Foo/late")
        let before = await engine.plan([try makeItem(d)])
        XCTAssertTrue(before.entries[0].isExecutable, "\(before.entries[0].blockers)")
        try writeUser("p.json", ruleFile(protect: #"["~/Library/Caches/Foo/late/**"]"#, paths: #"["~/.u/x"]"#, tier: "review"))
        let plan = await engine.plan([try makeItem(d)])
        XCTAssertFalse(plan.entries[0].isExecutable)
        XCTAssertTrue(plan.entries[0].blockers.contains { $0.code == "protectedPath" })
    }

    func testProtectAddedAfterPlanBlocksExecute() async throws {
        let engine = try defaultEngine(user: userDir)
        let d = try oldDir("Library/Caches/Foo/late2")
        let plan = await engine.plan([try makeItem(d)])
        XCTAssertTrue(plan.entries[0].isExecutable)
        try writeUser("p.json", ruleFile(protect: #"["~/Library/Caches/Foo/late2/**"]"#, paths: #"["~/.u/x"]"#, tier: "review"))
        let report = try await engine.execute(plan)
        guard case .skipped(let b)? = report.results.first?.outcome else { return XCTFail("\(report.results)") }
        XCTAssertTrue(b.contains { $0.code == "protectedPath" })
        XCTAssertTrue(FileManager.default.fileExists(atPath: d.path))
    }

    // MARK: F1 (fixed): untrusted policy blocks cleanup

    func testUntrustedPolicyBlocksEveryItem() async throws {
        let d = try oldDir("Library/Caches/Foo/x")
        let engine = try CleanupEngine.makeDefault(environment: env, bundledRulesDirectory: nil, userRulesDirectory: nil,
                                                   runningApps: FakeRunningApps(), inUse: FakeUsageSource([]),
                                                   userPolicy: { .empty }, userPolicyTrusted: { false })
        let plan = await engine.plan([try makeItem(d)])
        XCTAssertEqual(plan.entries[0].blockers, [.userPolicyUnavailable])
    }
}
