import XCTest
@testable import DiskKeeperCore

final class CareScanCoordinatorTests: XCTestCase {
    func testStagesRunInFixedOrderAndStrictlySequentially() async throws {
        let stages = [
            FakeStage.spec(.apps, modules: [.apps], items: [CareKit.item("/f/app", category: .application)], delay: .milliseconds(5)),
            FakeStage.spec(.rules, modules: [.aiTools], items: [CareKit.item("/f/r1"), CareKit.item("/f/r2")], delay: .milliseconds(5)),
            FakeStage.spec(.index, artifact: .tree(CareKit.syntheticTree())),
            FakeStage.spec(.duplicates, modules: [.duplicates], needsTree: true),
            FakeStage.spec(.largeOld, modules: [.largeOld], needsTree: true),
        ]
        let events = try await CareKit.run(stages)
        guard case .started(_, let order, _)? = events.first else { return XCTFail("started first") }
        XCTAssertEqual(order, [.rules, .index, .largeOld, .duplicates, .apps])
        XCTAssertEqual(CareKit.trace(events), [
            "start:rules", "item:rules", "item:rules", "finish:rules",
            "start:index", "finish:index",
            "start:largeOld", "finish:largeOld",
            "start:duplicates", "finish:duplicates",
            "start:apps", "item:apps", "finish:apps", "finished",
        ])
    }

    func testCancelMidPhaseKeepsDeliveredItemsAndNeverStartsLaterStages() async throws {
        let counter = CareCallCounter()
        let dir = try TemporaryDirectory()
        let history = CareHistoryStore(fileURL: dir.url.appendingPathComponent("h.json"))
        let hold = FakeStage.spec(.index, items: [], awaitCancel: true, counter: counter)
        let c = CareScanCoordinator(stages: [
            FakeStage.spec(.rules, modules: [.aiTools], items: [CareKit.item("/f/r1")], counter: counter),
            hold,
            FakeStage.spec(.largeOld, needsTree: true, counter: counter),
            FakeStage.spec(.apps, counter: counter),
        ], history: history, scopeFingerprint: "fp")
        let stream = try await c.scan()
        let collector = Task { await CareKit.collect(stream) }
        while counter.count(.index) == 0 { try await Task.sleep(for: .milliseconds(5)) }
        await c.cancel()
        await c.cancel()   // idempotent
        let events = await collector.value
        guard case .cancelled(let report)? = events.last else { return XCTFail("expected cancelled: \(CareKit.trace(events))") }
        XCTAssertTrue(report.wasCancelled)
        XCTAssertEqual(report.summaries[.aiTools]?.itemCount, 1, "delivered items are kept")
        XCTAssertEqual(counter.count(.largeOld), 0)
        XCTAssertEqual(counter.count(.apps), 0)
        XCTAssertNil(report.growth)
        XCTAssertTrue(history.load().isEmpty, "a cancelled scan appends no snapshot")
        XCTAssertFalse(CareKit.trace(events).contains("finish:index"))
        let running = await c.isRunning
        XCTAssertFalse(running)
    }

    func testFailingStageBecomesOneWarningAndOthersContinue() async throws {
        let counter = CareCallCounter()
        let events = try await CareKit.run([
            FakeStage.spec(.rules, modules: [.aiTools], items: [CareKit.item("/f/r1")], counter: counter),
            FakeStage.spec(.index, items: [], throwAfter: 0, counter: counter),
            FakeStage.spec(.apps, modules: [.apps], items: [CareKit.item("/f/a", category: .application)], counter: counter),
        ])
        let failed = events.compactMap { e -> (CareStage, ScanWarning)? in if case .stageFailed(let s, let w) = e { (s, w) } else { nil } }
        XCTAssertEqual(failed.count, 1)
        XCTAssertEqual(failed.first?.0, .index)
        XCTAssertEqual(failed.first?.1.kind, .scannerFailed)
        XCTAssertEqual(counter.count(.apps), 1)
        let report = try XCTUnwrap(CareKit.report(events))
        XCTAssertEqual(report.failedStages, [.index])
        XCTAssertFalse(report.wasCancelled)
        XCTAssertEqual(report.warnings.filter { $0.kind == .scannerFailed }.count, 1)
    }

    func testFailedIndexSkipsTreeStages() async throws {
        let counter = CareCallCounter()
        let events = try await CareKit.run([
            FakeStage.spec(.index, throwAfter: 0, counter: counter),
            FakeStage.spec(.largeOld, needsTree: true, counter: counter),
            FakeStage.spec(.duplicates, needsTree: true, counter: counter),
            FakeStage.spec(.apps, counter: counter),
        ])
        XCTAssertEqual(CareKit.trace(events), [
            "start:index", "fail:index", "skip:largeOld:needsTree", "skip:duplicates:needsTree",
            "start:apps", "finish:apps", "finished",
        ])
        XCTAssertEqual(counter.count(.largeOld) + counter.count(.duplicates), 0)
    }

    func testTreeStageReceivesTheIndexTree() async throws {
        let seen = TreeBox()
        let tree = CareKit.syntheticTree()
        let probe = CareStageSpec(stage: .largeOld, modules: [.largeOld], needsTree: true) { input, _ in
            seen.set(input.tree?.rootPath)
        }
        _ = try await CareKit.run([FakeStage.spec(.index, artifact: .tree(tree)), probe])
        XCTAssertEqual(seen.value, "/care-fixture")
    }

    func testSecondScanWhileRunningThrows() async throws {
        let c = CareScanCoordinator(stages: [FakeStage.spec(.rules, awaitCancel: true)], history: nil, scopeFingerprint: "x")
        let stream = try await c.scan()
        do { _ = try await c.scan(); XCTFail("expected alreadyRunning") } catch {
            XCTAssertEqual(error as? CareScanError, .alreadyRunning)
        }
        await c.cancel()
        _ = await CareKit.collect(stream)
        _ = try await c.scan()   // usable again
        await c.cancel()
    }

    func testDroppingTheStreamCancelsTheScan() async throws {
        let counter = CareCallCounter()
        let c = CareScanCoordinator(stages: [FakeStage.spec(.rules, awaitCancel: true, counter: counter)], history: nil, scopeFingerprint: "x")
        do {
            let stream = try await c.scan()
            withExtendedLifetime(stream) {}
        }
        while counter.count(.rules) == 0 { try await Task.sleep(for: .milliseconds(5)) }
        for _ in 0..<200 {
            if await !c.isRunning { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("scan kept running after the stream was dropped")
    }

    func testProgressIsCoalescedPerStage() async throws {
        let spec = CareStageSpec(stage: .rules, modules: []) { _, sink in
            for i in 0..<500 { await sink.progress(Double(i) / 500) }
            await sink.progress(1)
        }
        let events = try await CareKit.run([spec])
        let n = events.filter { if case .stageProgress = $0 { return true } else { return false } }.count
        XCTAssertLessThan(n, 50)
        XCTAssertGreaterThanOrEqual(n, 2, "the first and the 1.0 update always pass")
    }
}

final class TreeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var v: String?
    func set(_ s: String?) { lock.lock(); v = s; lock.unlock() }
    var value: String? { lock.lock(); defer { lock.unlock() }; return v }
}
