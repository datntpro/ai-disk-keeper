import XCTest
@testable import DiskKeeperCore
import protocol DiskKeeperCore.Scanner

final class ScanEngineCancellationTests: XCTestCase {
    private var fixture: FixtureHome!

    override func setUpWithError() throws { fixture = try FixtureHome() }
    override func tearDown() { fixture = nil }

    private func engine(_ scanners: [any Scanner]) throws -> (ScanEngine, ScanContext) {
        let context = ScanContext(environment: fixture.env, pathGuard: try ScanGuard(environment: fixture.env, protectPatterns: []),
                                  maxConcurrentSizing: 2)
        return (ScanEngine(context: context, scanners: scanners), context)
    }

    /// Emits one item, then blocks (cooperatively) until cancelled, never released.
    private func gated(count: Int = 200) -> ClosureScanner {
        let paths = (0..<count).map { fixture.abs(".g/d\($0)") }
        return ClosureScanner(id: "gate") { context, sink in
            for (n, p) in paths.enumerated() {
                if n == 1 { while true { try await Task.sleep(nanoseconds: 5_000_000) } }   // the gate
                await sink.item(EngineKit.item(p))
            }
        }
    }

    func testCancelMidScanYieldsCancelledAndNothingAfter() async throws {
        let late = fixture.abs(".late/x")
        // A scanner that ignores cancellation and keeps emitting: its items must never be delivered.
        let rogue = ClosureScanner(id: "rogue") { _, sink in
            do { while true { try await Task.sleep(nanoseconds: 5_000_000) } } catch {}
            await sink.item(EngineKit.item(late))
            await sink.warning(ScanWarning(kind: .other, message: "late"))
        }
        let (engine, context) = try engine([gated(), rogue])
        let stream = try await engine.scan()
        let collector = Task { () -> [ScanEvent] in
            var out: [ScanEvent] = []
            for await e in stream {
                out.append(e)
                if case .itemFound = e { await engine.cancel() }
            }
            return out
        }
        let timer = Task { try await Task.sleep(nanoseconds: 5_000_000_000); collector.cancel() }
        let events = await collector.value
        timer.cancel()
        let result = try XCTUnwrap(EngineKit.assertContract(events, pathGuard: context.pathGuard))
        guard case .cancelled? = events.last else { return XCTFail("last must be cancelled: \(String(describing: events.last))") }
        XCTAssertTrue(result.wasCancelled)
        XCTAssertFalse(result.items.map(\.path).contains(late))
        XCTAssertFalse(result.warnings.contains { $0.message == "late" })
        let running = await engine.isRunning
        XCTAssertFalse(running)
    }

    func testConsumerTerminationCancelsScan() async throws {
        let (engine, _) = try engine([gated()])
        let consumer = Task {
            let stream = try await engine.scan()
            for await e in stream { if case .itemFound = e { break } }
        }
        try await consumer.value
        var stopped = false
        for _ in 0..<400 {
            if await !engine.isRunning { stopped = true; break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(stopped, "scan must stop within 2 s after the consumer goes away")
    }

    /// #75 FU2: cancelling while a slow sizer is mid-walk stops promptly and emits no item.
    func testCancelDuringSizeStopsPromptlyWithNoItem() async throws {
        for i in 0..<200 { try fixture.file(".t/c/f\(i)", bytes: 10) }
        let rules = RuleFixtures.file(tool: "t", rules: [RuleFixtures.rule(id: "t.r", paths: #"["~/.t/c"]"#, match: #"{"kind":"self"}"#, tier: "safe", extra: "")])
        let loaded = try RuleHarness.loadRules(json: rules, fixture: fixture)
        var options = FileSizer.Options()
        options._entryHook = { usleep(20_000) }
        let context = ScanContext(environment: fixture.env, pathGuard: try ScanGuard(environment: fixture.env, protectPatterns: []),
                                  sizerOptions: options, maxConcurrentSizing: 1)
        let engine = ScanEngine(context: context, scanners: [RuleScanner(loadResult: loaded)])
        let stream = try await engine.scan()
        let collector = Task { () -> [ScanEvent] in var out: [ScanEvent] = []; for await e in stream { out.append(e) }; return out }
        try await Task.sleep(nanoseconds: 300_000_000)
        let start = Date()
        await engine.cancel()
        let events = await collector.value
        XCTAssertLessThan(Date().timeIntervalSince(start), 2.0, "cancel must not wait for the 4 s walk")
        XCTAssertFalse(events.contains { if case .itemFound = $0 { return true } else { return false } })
        guard case .cancelled? = events.last else { return XCTFail("last must be cancelled") }
    }

    func testCancelBeforeAnyItem() async throws {
        let (engine, context) = try engine([ClosureScanner(id: "idle") { _, _ in
            while true { try await Task.sleep(nanoseconds: 5_000_000) }
        }])
        let stream = try await engine.scan()
        await engine.cancel()
        let events = await EngineKit.collect(stream, timeout: 5)
        let result = try XCTUnwrap(EngineKit.assertContract(events, pathGuard: context.pathGuard))
        XCTAssertTrue(result.wasCancelled)
        XCTAssertTrue(result.items.isEmpty)
    }

    func testCancelIsIdempotentAndSafeWhenIdle() async throws {
        let (engine, _) = try engine([ClosureScanner(id: "x") { _, _ in }])
        await engine.cancel()
        await engine.cancel()
        let events = await EngineKit.collect(try await engine.scan())
        XCTAssertFalse(EngineKit.terminal(events)!.cancelled, "an idle cancel must not affect the next scan")
        await engine.cancel()
        await engine.cancel()
    }

    func testNewScanAfterCancelWorks() async throws {
        let ok = fixture.abs(".n/x")
        let (engine, context) = try engine([gated(), ClosureScanner(id: "ok") { _, sink in
            await sink.item(EngineKit.item(ok))
        }])
        let first = try await engine.scan()
        await engine.cancel()
        let firstEvents = await EngineKit.collect(first, timeout: 5)
        XCTAssertTrue(EngineKit.terminal(firstEvents)!.cancelled)
        let second = try await engine.scan()
        let consumer = Task { () -> [ScanEvent] in
            var out: [ScanEvent] = []
            for await e in second {
                out.append(e)
                if case .itemFound = e, EngineKit.items(out).count >= 2 { await engine.cancel() }
            }
            return out
        }
        let events = await consumer.value
        EngineKit.assertContract(events, pathGuard: context.pathGuard)
        XCTAssertTrue(EngineKit.items(events).map(\.path).contains(ok))
    }
}
