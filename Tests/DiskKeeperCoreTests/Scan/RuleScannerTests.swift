import XCTest
@testable import DiskKeeperCore

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var current = 0
    private(set) var peak = 0
    func enter() { lock.lock(); current += 1; peak = max(peak, current); lock.unlock() }
    func leave() { lock.lock(); current -= 1; lock.unlock() }
}

final class RuleScannerTests: XCTestCase {
    private var fixture: FixtureHome!
    private var restore: [String] = []
    private let now = Date()

    override func setUpWithError() throws { fixture = try FixtureHome() }

    override func tearDown() {
        for p in restore { chmod(p, 0o755) }
        restore = []
        fixture = nil
    }

    private func days(_ d: Double) -> Date { now.addingTimeInterval(-d * 86_400) }

    private func file(_ rules: String...) -> String { RuleFixtures.file(tool: "t", rules: rules) }

    private func rule(id: String = "t.r", paths: String = #"["~/.t/c"]"#, match: String = #"{"kind":"self"}"#,
                      tier: String = "safe", extra: String = "") -> String {
        RuleFixtures.rule(id: id, paths: paths, match: match, tier: tier, extra: extra)
    }

    private func run(_ json: String, userID: uid_t = getuid()) async throws -> HarnessResult {
        try await RuleHarness.run(json: json, fixture: fixture, now: now, userID: userID)
    }

    private func collect(_ scanner: RuleScanner, context: ScanContext) async throws -> (items: [ScanItem], warnings: [ScanWarning]) {
        let box = Box()
        let sink = ScanSink(item: { await box.add($0) }, warning: { await box.add($0) }, progress: { _ in })
        try await scanner.scan(context: context, sink: sink)
        return (await box.items, await box.warnings)
    }

    private actor Box {
        var items: [ScanItem] = []
        var warnings: [ScanWarning] = []
        func add(_ i: ScanItem) { items.append(i) }
        func add(_ w: ScanWarning) { warnings.append(w) }
    }

    private let ageTiers = #""tierWhen":[{"if":{"newerThanDays":7},"tier":"keep"},{"if":{"olderThanDays":30},"tier":"safe"}]"#

    func testTierFromNewestMtime() async throws {
        try fixture.file(".t/c/old", modified: days(100))
        try fixture.file(".t/c/new", modified: days(1))
        try fixture.dir(".t/c", modified: days(100))
        let r = try await run(file(rule(tier: "review", extra: ageTiers)))
        XCTAssertEqual(r.tier(fixture.abs(".t/c")), .keep)
    }

    func testTierWhenMostRestrictiveWins() async throws {
        try fixture.file(".t/c/old", modified: days(10))
        try fixture.dir(".t/c", modified: days(10))
        let extra = #""tierWhen":[{"if":{"olderThanDays":5},"tier":"safe"},{"if":{"olderThanDays":8},"tier":"review"}]"#
        let r = try await run(file(rule(tier: "safe", extra: extra)))
        XCTAssertEqual(r.tier(fixture.abs(".t/c")), .review)
    }

    func testMarkerExistsInsideOrBeside() async throws {
        try fixture.file(".t/c1/x/.m")
        try fixture.dir(".t/c1/z")
        try fixture.file(".t/c2/.m")
        try fixture.dir(".t/c2/y")
        let r = try await run(file(rule(
            paths: #"["~/.t/c1", "~/.t/c2"]"#, match: #"{"kind":"children","type":"directory"}"#,
            extra: #""tierWhen":[{"if":{"markerExists":".m"},"tier":"keep"}]"#)))
        XCTAssertEqual(r.tier(fixture.abs(".t/c1/x")), .keep)
        XCTAssertEqual(r.tier(fixture.abs(".t/c1/z")), .safe)
        XCTAssertEqual(r.tier(fixture.abs(".t/c2/y")), .keep)
    }

    func testOverlapEarlierRuleWinsOneWarningPerPair() async throws {
        try fixture.file(".t/c/a")
        try fixture.file(".t/c/b")
        let r = try await run(file(
            rule(id: "t.first", match: #"{"kind":"self"}"#),
            rule(id: "t.second", match: #"{"kind":"children"}"#)))
        XCTAssertEqual(r.items.map(\.ruleID), ["t.first"])
        let overlap = r.warnings.filter { $0.kind == .ruleError }
        XCTAssertEqual(overlap.count, 1)
        XCTAssertEqual(overlap.first?.ruleID, "t.second")
        XCTAssertTrue(overlap.first?.message.contains("t.first") == true)
    }

    func testItemFieldsFromRule() async throws {
        try fixture.file(".t/self/f", bytes: 100)
        try fixture.file(".t/kids/child.bin", bytes: 100)
        let r = try await run(file(
            rule(id: "t.self", paths: #"["~/.t/self"]"#, match: #"{"kind":"self"}"#,
                 extra: #""cleanup":{"method":"trash","requiresAppQuit":"com.example.app"}"#),
            rule(id: "t.kids", paths: #"["~/.t/kids"]"#, match: #"{"kind":"children"}"#,
                 extra: #""cleanup":{"method":"none"},"project":{"from":"itemName"}"#)))
        let s = try XCTUnwrap(r.item(fixture.abs(".t/self")))
        XCTAssertEqual(s.displayName, "R")
        XCTAssertEqual(s.tool, "t")
        XCTAssertEqual(s.cleanupMethod, .trash)
        XCTAssertEqual(s.requiresAppQuit, "com.example.app")
        XCTAssertEqual(s.category, .aiToolData)
        XCTAssertEqual(s.explanation, "x")
        XCTAssertEqual(s.fileCount, 1)
        XCTAssertGreaterThan(s.sizeAllocated, 0)
        let k = try XCTUnwrap(r.item(fixture.abs(".t/kids/child.bin")))
        XCTAssertEqual(k.displayName, "child.bin")
        XCTAssertEqual(k.cleanupMethod, CleanupMethod.none)
        XCTAssertEqual(k.project?.displayName, "child.bin")
    }

    func testProjectStrategies() async throws {
        try fixture.file(".t/p/proj1/a.jsonl")
        let r = try await run(file(rule(
            paths: #"["~/.t/p"]"#, match: #"{"kind":"children","depth":2,"glob":"*.jsonl","type":"file"}"#,
            extra: #""project":{"from":"claudeProjectDirName"}"#)))
        XCTAssertEqual(r.items.first?.project?.id, "name:proj1")
    }

    func testFlagsFromSizeReport() async throws {
        try fixture.file(".t/c1/ok", bytes: 10)
        let locked = fixture.abs(".t/c1/locked")
        try fixture.file(".t/c1/locked/x", bytes: 10)
        restore.append(locked)
        XCTAssertEqual(chmod(locked, 0), 0)
        try fixture.file("outside/data", bytes: 10)
        try fixture.file(".t/c2/dummy")
        XCTAssertEqual(link(fixture.abs("outside/data"), fixture.abs(".t/c2/linked")), 0)
        let r = try await run(file(
            rule(id: "t.a", paths: #"["~/.t/c1"]"#), rule(id: "t.b", paths: #"["~/.t/c2"]"#)))
        XCTAssertTrue(r.item(fixture.abs(".t/c1"))?.flags.contains(.sizeIncomplete) == true)
        XCTAssertTrue(r.item(fixture.abs(".t/c2"))?.flags.contains(.sharedStorage) == true)
    }

    func testVanishedBetweenExpandAndSizeIsSilent() async throws {
        try fixture.file(".t/c/f")
        let loaded = try RuleHarness.loadRules(json: file(rule()), fixture: fixture)
        var scanner = RuleScanner(loadResult: loaded)
        let path = fixture.abs(".t/c")
        scanner._afterExpand = { try? FileManager.default.removeItem(atPath: path) }
        let (items, warnings) = try await collect(scanner, context: RuleHarness.context(fixture, loaded: loaded))
        XCTAssertTrue(items.isEmpty)
        XCTAssertTrue(warnings.isEmpty)
    }

    func testConcurrencyBoundRespected() async throws {
        for i in 0..<8 { try fixture.file(".t/c/d\(i)/f") }
        let loaded = try RuleHarness.loadRules(json: file(rule(match: #"{"kind":"children"}"#)), fixture: fixture)
        let counter = Counter()
        var options = FileSizer.Options()
        options._entryHook = { counter.enter(); usleep(20_000); counter.leave() }
        let context = try RuleHarness.context(fixture, loaded: loaded, sizerOptions: options, maxConcurrentSizing: 2)
        let (items, _) = try await collect(RuleScanner(loadResult: loaded), context: context)
        XCTAssertEqual(items.count, 8)
        XCTAssertLessThanOrEqual(counter.peak, 2)
        XCTAssertGreaterThanOrEqual(counter.peak, 1)
    }

    func testCancellationPropagates() async throws {
        for i in 0..<20 { try fixture.file(".t/c/d\(i)/f") }
        let loaded = try RuleHarness.loadRules(json: file(rule(match: #"{"kind":"children"}"#)), fixture: fixture)
        var options = FileSizer.Options()
        options._entryHook = { usleep(30_000) }
        let context = try RuleHarness.context(fixture, loaded: loaded, sizerOptions: options, maxConcurrentSizing: 2)
        let scanner = RuleScanner(loadResult: loaded)
        let box = Box()
        let sink = ScanSink(item: { await box.add($0) }, warning: { _ in }, progress: { _ in })
        let task = Task { try await scanner.scan(context: context, sink: sink) }
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        do {
            try await task.value
            XCTFail("expected CancellationError")
        } catch is CancellationError {
        }
        let count = await box.items.count
        XCTAssertLessThan(count, 20)
    }

    func testOtherUsersFilesSkipped() async throws {
        try fixture.file(".t/c/f")
        let r = try await run(file(rule(), rule(id: "t.k", paths: #"["~/.t/c"]"#, match: #"{"kind":"children"}"#)),
                              userID: getuid() + 1)
        XCTAssertTrue(r.items.isEmpty)
        XCTAssertTrue(r.warnings.isEmpty)
    }

    func testReadOnly() async throws {
        try fixture.file(".t/c/a/f", bytes: 100)
        try fixture.file(".t/c/b", bytes: 5)
        try fixture.symlink(".t/c/l", to: fixture.abs(".t"))
        let before = try fixture.snapshot()
        let r = try await run(file(rule(match: #"{"kind":"children"}"#), rule(id: "t.s", paths: #"["~/.t"]"#)))
        XCTAssertFalse(r.items.isEmpty)
        XCTAssertEqual(try fixture.snapshot(), before)
    }

    func testProgressReported() async throws {
        for i in 0..<3 { try fixture.file(".t/c/f\(i)") }
        let loaded = try RuleHarness.loadRules(json: file(rule(match: #"{"kind":"children"}"#)), fixture: fixture)
        let last = Box2()
        let sink = ScanSink(item: { _ in }, warning: { _ in }, progress: { await last.set($0) })
        try await RuleScanner(loadResult: loaded).scan(context: RuleHarness.context(fixture, loaded: loaded), sink: sink)
        let p = await last.value
        XCTAssertEqual(p?.candidatesFound, 3)
        XCTAssertEqual(p?.candidatesSized, 3)
    }

    func testSamePhysicalDirViaSymlinkedAncestorIsEmittedOnce() async throws {
        try fixture.dir(".t/x/a")
        try fixture.symlink(".u", to: fixture.abs(".t"))
        let r = try await run(file(
            rule(id: "t.a", paths: #"["~/.t/x"]"#, match: #"{"kind":"children"}"#),
            rule(id: "t.b", paths: #"["~/.u/x"]"#, match: #"{"kind":"children"}"#)))
        XCTAssertEqual(r.items.map(\.path), [fixture.abs(".t/x/a")])
        let overlap = r.warnings.filter { $0.kind == .ruleError }
        XCTAssertEqual(overlap.count, 1)
        XCTAssertEqual(overlap.first?.ruleID, "t.b")
        XCTAssertTrue(overlap.first?.message.contains("t.a") == true)
    }

    func testDropStatsAreSurfacedInProgress() async throws {
        try fixture.dir(".claude/projects/p/memory")
        try fixture.dir(".claude/projects/p/other")
        let loaded = try RuleHarness.loadRules(json: file(rule(
            paths: #"["~/.claude/projects"]"#, match: #"{"kind":"children","depth":2,"type":"directory"}"#)), fixture: fixture)
        let last = Box2()
        let sink = ScanSink(item: { _ in }, warning: { _ in }, progress: { await last.set($0) })
        try await RuleScanner(loadResult: loaded).scan(context: RuleHarness.context(fixture, loaded: loaded), sink: sink)
        let p = await last.value
        XCTAssertEqual(p?.guardDropped, 1)
        XCTAssertEqual(p?.ownerDropped, 0)
        let other = Box2()
        let sink2 = ScanSink(item: { _ in }, warning: { _ in }, progress: { await other.set($0) })
        try await RuleScanner(loadResult: loaded).scan(
            context: RuleHarness.context(fixture, loaded: loaded, userID: getuid() + 1), sink: sink2)
        let q = await other.value
        XCTAssertEqual(q?.ownerDropped, 1)
    }

    private actor Box2 {
        var value: ScannerProgress?
        func set(_ p: ScannerProgress) { value = p }
    }
}
