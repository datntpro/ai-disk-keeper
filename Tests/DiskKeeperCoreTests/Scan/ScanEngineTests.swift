import XCTest
@testable import DiskKeeperCore
import protocol DiskKeeperCore.Scanner

/// Closure-backed scanner for engine tests.
struct ClosureScanner: Scanner {
    let id: String
    let body: @Sendable (ScanContext, ScanSink) async throws -> Void
    func scan(context: ScanContext, sink: ScanSink) async throws { try await body(context, sink) }
}

struct TestScanFailure: Error {}

enum EngineKit {
    static func item(_ path: String, rule: String = "t.r", tier: RiskTier = .safe, size: Int64 = 1) -> ScanItem {
        ScanItem(url: URL(fileURLWithPath: path), displayName: (path as NSString).lastPathComponent, tool: "t",
                 category: .aiToolData, sizeAllocated: size, sizeLogical: size, fileCount: 1,
                 lastModified: nil, tier: tier, explanation: "x", ruleID: rule)
    }

    /// Collects the whole stream; a timeout cancels the consumer (so the test fails instead of hanging).
    static func collect(_ stream: AsyncStream<ScanEvent>, timeout: Double = 30) async -> [ScanEvent] {
        let collector = Task { () -> [ScanEvent] in
            var out: [ScanEvent] = []
            for await e in stream { out.append(e) }
            return out
        }
        let timer = Task {
            try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            collector.cancel()
        }
        let events = await collector.value
        timer.cancel()
        return events
    }

    static func items(_ events: [ScanEvent]) -> [ScanItem] {
        events.compactMap { if case .itemFound(let i) = $0 { return i } else { return nil } }
    }
    static func warnings(_ events: [ScanEvent]) -> [ScanWarning] {
        events.compactMap { if case .warning(let w) = $0 { return w } else { return nil } }
    }
    static func progress(_ events: [ScanEvent]) -> [ScanProgress] {
        events.compactMap { if case .progress(let p) = $0 { return p } else { return nil } }
    }
    static func terminal(_ events: [ScanEvent]) -> (result: ScanResult, cancelled: Bool)? {
        switch events.last {
        case .finished(let r): return (r, false)
        case .cancelled(let r): return (r, true)
        default: return nil
        }
    }

    /// Checks the stream contract; returns the terminal result.
    @discardableResult
    static func assertContract(_ events: [ScanEvent], pathGuard: ScanGuard,
                               file: StaticString = #filePath, line: UInt = #line) -> ScanResult? {
        guard case .started? = events.first else {
            XCTFail("first event must be started", file: file, line: line); return nil
        }
        XCTAssertEqual(events.filter { if case .started = $0 { return true } else { return false } }.count, 1,
                       file: file, line: line)
        let terminals = events.enumerated().filter {
            switch $0.element { case .finished, .cancelled: return true; default: return false }
        }
        XCTAssertEqual(terminals.map(\.offset), [events.count - 1], "exactly one terminal event, last",
                       file: file, line: line)
        let found = items(events)
        for i in found { XCTAssertTrue(pathGuard.check(i.path).isAllowed, "\(i.path)", file: file, line: line) }
        var claims = PathClaimSet()
        for i in found { XCTAssertNil(claims.claim(i.path), "overlap: \(i.path)", file: file, line: line) }
        guard let t = terminal(events) else { return nil }
        XCTAssertEqual(t.result.items, found, file: file, line: line)
        XCTAssertEqual(t.result.wasCancelled, t.cancelled, file: file, line: line)
        XCTAssertNotNil(t.result.finishedAt, file: file, line: line)
        return t.result
    }
}

final class ScanEngineTests: XCTestCase {
    private var fixture: FixtureHome!
    private var rulesDir: TemporaryDirectory!
    private let now = Date()

    override func setUpWithError() throws {
        fixture = try FixtureHome()
        rulesDir = try TemporaryDirectory()
    }

    override func tearDown() {
        fixture = nil
        rulesDir = nil
    }

    private func days(_ d: Double) -> Date { now.addingTimeInterval(-d * 86_400) }

    private func makeEngine(extra: [any Scanner] = [], progressInterval: Duration = .milliseconds(100)) throws -> ScanEngine {
        let base = try ScanEngine.makeDefault(
            environment: fixture.env, bundledRulesDirectory: rulesDir.url, extraScanners: extra,
            maxConcurrentSizing: 2, now: now)
        return base
    }

    private func engine(scanners: [any Scanner], progressInterval: Duration = .milliseconds(100)) throws -> (ScanEngine, ScanContext) {
        let loaded = RuleLoader(environment: fixture.env, bundledRulesDirectory: rulesDir.url, userRulesDirectory: nil,
                                guardFactory: ScanGuard.loaderFactory(environment: fixture.env)).load()
        let context = try RuleHarness.context(fixture, loaded: loaded, now: now, maxConcurrentSizing: 2)
        return (ScanEngine(context: context, scanners: scanners, progressInterval: progressInterval), context)
    }

    private func writeRules(_ files: [String: String]) throws {
        for (name, json) in files { try rulesDir.file(name, contents: Data(json.utf8)) }
    }

    func testFixtureHomeIntegrationItemsAndTiers() async throws {
        try fixture.file(".t/projects/a.jsonl", bytes: 10, modified: days(2))
        try fixture.file(".t/projects/b.jsonl", bytes: 10, modified: days(10))
        try fixture.file(".t/projects/c.jsonl", bytes: 10, modified: days(40))
        try fixture.file(".t/cache/blob", bytes: 100)
        try fixture.file(".claude/projects/p/memory/note.md", bytes: 5)
        try fixture.file(".claude/projects/p/other/x", bytes: 5)
        let tiers = #""tierWhen":[{"if":{"newerThanDays":7},"tier":"keep"},{"if":{"olderThanDays":30},"tier":"safe"}]"#
        try writeRules([
            "t.json": RuleFixtures.file(tool: "t", rules: [
                RuleFixtures.rule(id: "t.transcripts", paths: #"["~/.t/projects"]"#,
                                  match: #"{"kind":"children","glob":"*.jsonl","type":"file"}"#, tier: "review", extra: tiers),
                RuleFixtures.rule(id: "t.cache", paths: #"["~/.t/cache"]"#),
            ]),
            "claude.json": RuleFixtures.file(tool: "c", rules: [
                RuleFixtures.rule(id: "c.projects", paths: #"["~/.claude/projects"]"#,
                                  match: #"{"kind":"children","depth":2,"glob":"*","type":"directory"}"#),
            ]),
            "absent.json": RuleFixtures.file(tool: "absent", rules: [
                RuleFixtures.rule(id: "absent.r", paths: #"["~/.absent/x"]"#),
            ]),
        ])
        let engine = try makeEngine()
        let events = await EngineKit.collect(try await engine.scan())
        let result = try XCTUnwrap(EngineKit.assertContract(events, pathGuard: try ScanGuard(
            environment: fixture.env, protectPatterns: [])))
        XCTAssertFalse(result.wasCancelled)
        let got = Set(result.items.map { "\($0.path)=\($0.tier.rawValue)" })
        XCTAssertEqual(got, [
            fixture.abs(".t/projects/a.jsonl") + "=keep",
            fixture.abs(".t/projects/b.jsonl") + "=review",
            fixture.abs(".t/projects/c.jsonl") + "=safe",
            fixture.abs(".t/cache") + "=safe",
            fixture.abs(".claude/projects/p/other") + "=safe",
        ])
        XCTAssertTrue(result.warnings.isEmpty, "\(result.warnings)")
        let running = await engine.isRunning
        XCTAssertFalse(running)
    }

    func testEventOrderStartedFirstTerminalLast() async throws {
        let (engine, context) = try engine(scanners: [
            ClosureScanner(id: "a") { _, sink in await sink.item(EngineKit.item(self.fixture.abs(".a/x"))) },
        ])
        let events = await EngineKit.collect(try await engine.scan())
        EngineKit.assertContract(events, pathGuard: context.pathGuard)
        if case .started(_, _, let ids)? = events.first { XCTAssertEqual(ids, ["a"]) } else { XCTFail() }
        XCTAssertEqual(EngineKit.items(events).count, 1)
    }

    func testRuleLoadErrorsBecomeWarnings() async throws {
        try fixture.file(".t/cache/blob")
        try writeRules([
            "good.json": RuleFixtures.file(tool: "t", rules: [RuleFixtures.rule(id: "t.cache", paths: #"["~/.t/cache"]"#)]),
            "broken.json": "{ not json",
        ])
        let events = await EngineKit.collect(try await makeEngine().scan())
        let warnings = EngineKit.warnings(events)
        XCTAssertEqual(warnings.filter { $0.kind == .ruleError && $0.path?.hasSuffix("broken.json") == true }.count, 1,
                       "\(warnings)")
        XCTAssertEqual(EngineKit.items(events).map(\.path), [fixture.abs(".t/cache")])
    }

    func testGuardUnavailableThrows() throws {
        let env = PathEnvironment(home: "/", temporaryDirectory: fixture.tempDir, variables: [:])
        XCTAssertThrowsError(try ScanEngine.makeDefault(environment: env, bundledRulesDirectory: rulesDir.url))
    }

    func testEngineDropsItemsDeniedByGuardFromCodeScanners() async throws {
        let ssh = fixture.abs(".ssh/x"), ok = fixture.abs(".ok/x")
        let (engine, context) = try engine(scanners: [
            ClosureScanner(id: "bad") { _, sink in
                await sink.item(EngineKit.item(ssh))
                await sink.item(EngineKit.item(ok))
            },
        ])
        let events = await EngineKit.collect(try await engine.scan())
        EngineKit.assertContract(events, pathGuard: context.pathGuard)
        XCTAssertEqual(EngineKit.items(events).map(\.path), [ok])
    }

    func testCrossScannerOverlapFirstWins() async throws {
        let a = fixture.abs(".o/a"), b = fixture.abs(".o/a/b")
        let (engine, context) = try engine(scanners: [
            ClosureScanner(id: "one") { _, sink in await sink.item(EngineKit.item(a, rule: "o.one")) },
            ClosureScanner(id: "two") { _, sink in await sink.item(EngineKit.item(b, rule: "o.two")) },
        ])
        let events = await EngineKit.collect(try await engine.scan())
        EngineKit.assertContract(events, pathGuard: context.pathGuard)
        XCTAssertEqual(EngineKit.items(events).count, 1)
        XCTAssertEqual(EngineKit.warnings(events).filter { $0.kind == .ruleError }.count, 1)
    }

    func testScannerFailureIsWarningAndOthersContinue() async throws {
        let keep = fixture.abs(".k/x"), early = fixture.abs(".k/early")
        let (engine, context) = try engine(scanners: [
            ClosureScanner(id: "boom") { _, sink in
                await sink.item(EngineKit.item(early))
                throw TestScanFailure()
            },
            ClosureScanner(id: "fine") { _, sink in await sink.item(EngineKit.item(keep)) },
        ])
        let events = await EngineKit.collect(try await engine.scan())
        EngineKit.assertContract(events, pathGuard: context.pathGuard)
        XCTAssertEqual(Set(EngineKit.items(events).map(\.path)), [keep, early])
        let failed = EngineKit.warnings(events).filter { $0.kind == .scannerFailed }
        XCTAssertEqual(failed.count, 1)
        XCTAssertTrue(failed[0].message.hasPrefix("boom:"))
        XCTAssertFalse(EngineKit.terminal(events)!.cancelled)
    }

    func testProgressThrottledAndFinalProgressSent() async throws {
        let (engine, _) = try engine(scanners: [
            ClosureScanner(id: "p") { _, sink in
                for n in 1...20 { await sink.progress(ScannerProgress(candidatesFound: n, candidatesSized: n)) }
            },
        ], progressInterval: .seconds(3600))
        let events = await EngineKit.collect(try await engine.scan())
        let progress = EngineKit.progress(events)
        XCTAssertEqual(progress.count, 1)
        XCTAssertEqual(progress.first?.candidatesFound, 20)
        XCTAssertEqual(progress.first?.scannersFinished, 1)
        XCTAssertEqual(progress.first?.scannersTotal, 1)
        // The final progress is the event right before the terminal one.
        if case .progress? = events.dropLast().last {} else { XCTFail("final progress must precede terminal") }
    }

    func testAlreadyRunningThrows() async throws {
        let (engine, _) = try engine(scanners: [
            ClosureScanner(id: "slow") { _, _ in try await Task.sleep(nanoseconds: 300_000_000) },
        ])
        let stream = try await engine.scan()
        do {
            _ = try await engine.scan()
            XCTFail("expected alreadyRunning")
        } catch let error as ScanEngineError {
            XCTAssertEqual(error, .alreadyRunning)
        }
        let events = await EngineKit.collect(stream)
        XCTAssertFalse(EngineKit.terminal(events)!.cancelled)
    }

    func testExampleScannerFromDocs() async throws {
        try fixture.file(".logs/a.log", bytes: 100)
        try fixture.file(".logs/b.log", bytes: 100)
        try fixture.file(".logs/c.txt", bytes: 100)
        let (engine, context) = try engine(scanners: [ExampleScanner(directory: fixture.abs(".logs"))])
        let events = await EngineKit.collect(try await engine.scan())
        EngineKit.assertContract(events, pathGuard: context.pathGuard)
        XCTAssertEqual(EngineKit.items(events).map(\.path), [fixture.abs(".logs/a.log"), fixture.abs(".logs/b.log")])
        XCTAssertTrue(EngineKit.items(events).allSatisfy { $0.category == .systemJunk })
    }

    func testLoaderWarningsBecomeWarnings() async throws {
        try fixture.file(".t/cache/blob")
        // ~/.ssh is protected: the rule path is dropped with a loader warning (not an error).
        try writeRules(["w.json": RuleFixtures.file(tool: "t", rules: [
            RuleFixtures.rule(id: "t.cache", paths: #"["~/.t/cache", "~/.ssh"]"#)])])
        let events = await EngineKit.collect(try await makeEngine().scan())
        let warnings = EngineKit.warnings(events)
        XCTAssertTrue(warnings.contains { $0.kind == .ruleError && $0.message.contains(".ssh") }, "\(warnings)")
        XCTAssertEqual(EngineKit.items(events).map(\.path), [fixture.abs(".t/cache")])
    }

    func testProgressAdvancesWithoutScannerProgressCalls() async throws {
        let paths = (0..<8).map { fixture.abs(".h/d\($0)") }
        let (engine, _) = try engine(scanners: [
            ClosureScanner(id: "slow") { _, sink in
                for p in paths {
                    await sink.item(EngineKit.item(p))
                    try await Task.sleep(nanoseconds: 80_000_000)
                }
            },
        ], progressInterval: .milliseconds(100))
        let events = await EngineKit.collect(try await engine.scan())
        XCTAssertGreaterThanOrEqual(EngineKit.progress(events).count, 3, "heartbeat/trailing-edge progress expected")
    }

    func testCrossScannerOverlapThroughSymlinkedParentIsDetected() async throws {
        try fixture.dir(".real/cache")
        try fixture.symlink(".alias", to: fixture.abs(".real"))
        let (engine, context) = try engine(scanners: [
            ClosureScanner(id: "one") { _, sink in await sink.item(EngineKit.item(self.fixture.abs(".real/cache"), rule: "o.one")) },
            ClosureScanner(id: "two") { _, sink in
                try await Task.sleep(nanoseconds: 50_000_000)
                await sink.item(EngineKit.item(self.fixture.abs(".alias/cache"), rule: "o.two"))
            },
        ])
        let events = await EngineKit.collect(try await engine.scan())
        EngineKit.assertContract(events, pathGuard: context.pathGuard)
        XCTAssertEqual(EngineKit.items(events).map(\.ruleID), ["o.one"])
        XCTAssertEqual(EngineKit.warnings(events).filter { $0.kind == .ruleError }.count, 1)
    }

    func testOverlapWarningsDeduplicatedPerRulePair() async throws {
        let (engine, _) = try engine(scanners: [
            ClosureScanner(id: "one") { _, sink in await sink.item(EngineKit.item(self.fixture.abs(".o/a"), rule: "o.one")) },
            ClosureScanner(id: "two") { _, sink in
                try await Task.sleep(nanoseconds: 50_000_000)
                for i in 0..<5 { await sink.item(EngineKit.item(self.fixture.abs(".o/a/\(i)"), rule: "o.two")) }
            },
        ])
        let events = await EngineKit.collect(try await engine.scan())
        XCTAssertEqual(EngineKit.warnings(events).filter { $0.kind == .ruleError }.count, 1)
    }

    func testSelfThrownCancellationWithoutScanCancelIsAFailure() async throws {
        let (engine, _) = try engine(scanners: [ClosureScanner(id: "t") { _, _ in throw CancellationError() }])
        let events = await EngineKit.collect(try await engine.scan())
        XCTAssertEqual(EngineKit.warnings(events).filter { $0.kind == .scannerFailed }.count, 1)
        XCTAssertFalse(EngineKit.terminal(events)!.cancelled)
    }

    func testExampleScannerMissingDirectoryIsSilent() async throws {
        let (engine, _) = try engine(scanners: [ExampleScanner(directory: fixture.abs(".nope"))])
        let events = await EngineKit.collect(try await engine.scan())
        XCTAssertTrue(EngineKit.warnings(events).isEmpty)
        XCTAssertTrue(EngineKit.items(events).isEmpty)
    }

    func testDocsContainTheExampleVerbatim() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Tests/DiskKeeperCoreTests/Scan/ExampleScanner.swift"),
                                encoding: .utf8)
        let docs = try String(contentsOf: root.appendingPathComponent("docs/scanners.md"), encoding: .utf8)
        let code = try XCTUnwrap(source.components(separatedBy: "// EXAMPLE-BEGIN\n").dropFirst().first?
            .components(separatedBy: "// EXAMPLE-END").first)
        XCTAssertTrue(docs.contains(code), "docs/scanners.md must contain ExampleScanner.swift verbatim")
    }
}
