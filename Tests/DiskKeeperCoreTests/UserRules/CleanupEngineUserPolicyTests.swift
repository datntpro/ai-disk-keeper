import XCTest
@testable import DiskKeeperCore

/// Policy changes made after a plan are enforced at execute time.
final class CleanupEngineUserPolicyTests: CleanupTestCase {
    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var value = UserPolicy.empty
        var policy: UserPolicy { get { lock.lock(); defer { lock.unlock() }; return value }
                                 set { lock.lock(); value = newValue; lock.unlock() } }
    }
    private let box = Box()

    private func engine() throws -> CleanupEngine {
        CleanupEngine(pathGuard: try makeGuard(), auditLog: AuditLog(fileURL: auditURL),
                      trash: DirectoryTrash(root: trashDir), runningApps: FakeRunningApps(),
                      userPolicy: { [box] in box.policy })
    }

    private func make() throws -> ScanItem {
        _ = try fx.file("home/cache/a.bin", bytes: 100)
        return try item("home/cache")
    }

    func testItemIgnoredAfterPlanIsNotTrashed() async throws {
        let it = try make()
        let e = try engine()
        let plan = await e.plan([it])
        XCTAssertTrue(plan.entries[0].isExecutable)
        box.policy = UserPolicy(ignoredItemIDs: [it.id])
        let report = try await e.execute(plan)
        guard case .skipped(let b)? = report.results.first?.outcome else { return XCTFail("\(report.results)") }
        XCTAssertTrue(b.contains(.ignoredByUser))
        XCTAssertTrue(exists("home/cache/a.bin"))
        XCTAssertTrue(trashContents().isEmpty)
    }

    func testRuleDisabledAfterPlanBlocks() async throws {
        let it = try make()
        let e = try engine()
        let plan = await e.plan([it])
        box.policy = UserPolicy(disabledRuleIDs: [it.ruleID])
        let report = try await e.execute(plan)
        guard case .skipped(let b)? = report.results.first?.outcome else { return XCTFail() }
        XCTAssertTrue(b.contains(.ignoredByUser))
        XCTAssertTrue(trashContents().isEmpty)
    }

    func testKeepOverrideAfterPlanBlocksAsKeepTier() async throws {
        let it = try make()
        let e = try engine()
        let plan = await e.plan([it])
        box.policy = UserPolicy(tierOverrides: [it.id: .keep])
        let report = try await e.execute(plan)
        guard case .skipped(let b)? = report.results.first?.outcome else { return XCTFail() }
        XCTAssertEqual(b, [.keepTier])
        XCTAssertTrue(trashContents().isEmpty)
    }

    func testIgnoredAtPlanTimeIsBlockedInThePlan() async throws {
        let it = try make()
        box.policy = UserPolicy(ignoredItemIDs: [it.id])
        let plan = await (try engine()).plan([it])
        XCTAssertEqual(plan.entries[0].blockers, [.ignoredByUser])
    }

    func testReviewOverrideDoesNotBlockAndLooserOverrideNeverUnblocks() async throws {
        let it = try make()
        box.policy = UserPolicy(tierOverrides: [it.id: .review])
        let e = try engine()
        let p1 = await e.plan([it])
        XCTAssertTrue(p1.entries[0].isExecutable)
        let kept = try { var k = it; k.tier = .keep; return k }()
        box.policy = UserPolicy(tierOverrides: [it.id: .safe])
        let p2 = await e.plan([kept])
        XCTAssertEqual(p2.entries[0].blockers, [.keepTier], "an override can't lift Keep")
    }

    func testDefaultEngineUsesUserProtectFromTheUserFolder() async throws {
        let tmp = try TemporaryDirectory()
        let home = try tmp.dir("home")
        let env = PathEnvironment(home: home.path, temporaryDirectory: tmp.path("tmp"))
        let blob = try tmp.file("home/Library/Caches/Foo/keepme/blob", bytes: 10)
        let dir = blob.deletingLastPathComponent()
        let old = Date(timeIntervalSince1970: 1_577_836_800)
        for p in [blob.path, dir.path] { try setMTime(p, old) }
        let rules = env.userRulesDirectory
        try FileManager.default.createDirectory(at: rules, withIntermediateDirectories: true)
        let json = #"{"schemaVersion":1,"tool":{"id":"foo","name":"Foo"},"protect":["~/Library/Caches/Foo/keepme/**"],"rules":[{"id":"foo.r","title":"R","category":"aiToolData","paths":["~/.foo/x"],"match":{"kind":"self"},"tier":"review","explanation":"x"}]}"#
        try Data(json.utf8).write(to: rules.appendingPathComponent("foo.json"))

        func plan(_ userDir: URL?) async throws -> CleanupPlan {
            let engine = try CleanupEngine.makeDefault(environment: env, userRulesDirectory: userDir,
                                                       runningApps: FakeRunningApps(), inUse: FakeUsageSource([]))
            let r = try FileSizer().sizeBlocking(of: dir)
            let it = ScanItem(url: dir, displayName: "keepme", tool: "foo", category: .systemJunk, sizeAllocated: r.allocatedBytes,
                              sizeLogical: r.logicalBytes, fileCount: r.fileCount, lastModified: r.newestModification,
                              tier: .safe, explanation: "x", ruleID: "foo.r")
            return await engine.plan([it])
        }
        let without = try await plan(nil)
        XCTAssertTrue(without.entries[0].isExecutable, "\(without.entries[0].blockers)")
        let loaded = RuleLoader(environment: env, bundledRulesDirectory: nil, userRulesDirectory: rules,
                                guardFactory: ScanGuard.loaderFactory(environment: env)).load()
        XCTAssertEqual(loaded.errors, [])
        XCTAssertEqual(loaded.protectPatterns.count, 1)
        let with = try await plan(rules)
        XCTAssertTrue(with.entries[0].blockers.contains { $0.code == "protectedPath" }, "\(with.entries[0].blockers)")
    }
}
