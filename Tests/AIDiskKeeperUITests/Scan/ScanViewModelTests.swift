import DiskKeeperCore
import XCTest
@testable import AIDiskKeeperUI

@MainActor
final class ScanViewModelTests: XCTestCase {
    private typealias F = ItemFixtures

    private func until(_ what: String = "condition", _ cond: @MainActor () -> Bool) async {
        for _ in 0..<400 {
            if cond() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("timed out waiting for \(what)")
    }

    func testEventOrderAndTotals() async {
        let a = F.item("a", tier: .safe, size: 300), b = F.item("b", tier: .review, size: 200)
        let events: [ScanEvent] = [
            .started(id: UUID(), startedAt: F.t0, scannerIDs: ["x"]), .itemFound(a), .itemFound(b),
            .progress(F.progress(found: 2, bytes: 500)), .finished(F.result([a, b]))]
        let vm = ScanViewModel { FakeScanEngine(.scripted(events)) }
        vm.startScan()
        await until("finished") { vm.phase == .finished }
        XCTAssertEqual(vm.items, vm.result?.items)
        XCTAssertEqual(vm.totals.all.allocatedBytes, 500)
        XCTAssertEqual(vm.totals.byTier[.safe]?.itemCount, 1)
        XCTAssertEqual(vm.totals.bulkSelectable.allocatedBytes, 300)
        XCTAssertNotNil(vm.lastScanFinishedAt)
    }

    func testItemsAdjustedReplacesByIdAndRetotals() async {
        let a = F.item("a", tier: .safe, size: 300), b = F.item("b", tier: .safe, size: 200)
        var held = a; held.tier = .keep; held.flags.insert(.inUse); held.inUseBy = "tail"
        let engine = FakeScanEngine(.gated)
        let vm = ScanViewModel { engine }
        vm.startScan()
        await until("scanning") { vm.phase == .scanning }
        await engine.send(.itemFound(a))
        await engine.send(.progress(F.progress(found: 1)))
        await until("flush") { vm.items.count == 1 }
        await engine.send(.itemFound(b))
        await engine.send(.itemsAdjusted([held]))
        await until("adjusted") { vm.items.first?.tier == .keep }
        XCTAssertEqual(vm.items.count, 2, "the still-pending item is flushed too")
        XCTAssertEqual(vm.totals.byTier[.safe]?.itemCount, 1)
        XCTAssertEqual(vm.items.first?.inUseBy, "tail")
        await engine.send(.finished(F.result([held, b])))
        await until("finished") { vm.phase == .finished }
    }

    func testItemsBatchedUntilProgressOrTerminal() async {
        let a = F.item("a"), b = F.item("b")
        let engine = FakeScanEngine(.gated)
        let vm = ScanViewModel { engine }
        vm.startScan()
        await until("scanning") { vm.phase == .scanning }
        await engine.send(.itemFound(a))
        await engine.send(.warning(ScanWarning(kind: .other, message: "w")))
        await until("warning") { vm.warnings.count == 1 }
        XCTAssertTrue(vm.items.isEmpty, "items stay buffered until a progress event")
        await engine.send(.progress(F.progress(found: 1)))
        await until("flush") { vm.items.count == 1 }
        await engine.send(.itemFound(b))
        await engine.send(.finished(F.result([a, b])))
        await until("finished") { vm.phase == .finished }
        XCTAssertEqual(vm.items.count, 2)
    }

    func testCancelKeepsPartialItems() async {
        let a = F.item("a")
        let engine = FakeScanEngine(.gated)
        let vm = ScanViewModel { engine }
        vm.startScan()
        await until("scanning") { vm.phase == .scanning }
        await engine.send(.itemFound(a))
        vm.cancelScan()
        XCTAssertEqual(vm.phase, .cancelling)
        await until("cancelled") { vm.phase == .cancelled }
        XCTAssertEqual(vm.items, [a])
        XCTAssertEqual(vm.result?.wasCancelled, true)
        let calls = await engine.cancelCalls
        XCTAssertEqual(calls, 1)
    }

    func testStreamEndingWithoutTerminalBecomesCancelled() async {
        let a = F.item("a")
        let vm = ScanViewModel { FakeScanEngine(.scripted([.itemFound(a)])) }
        vm.startScan()
        await until("cancelled") { vm.phase == .cancelled }
        XCTAssertEqual(vm.items, [a])
    }

    func testFactoryThrowsGivesFailed() async {
        struct Boom: Error {}
        let vm = ScanViewModel { throw Boom() }
        vm.startScan()
        await until("failed") { if case .failed = vm.phase { return true } else { return false } }
        XCTAssertFalse(vm.isScanning)
    }

    func testStartWhileScanningIsNoOp() async {
        let counter = Counter()
        let engine = FakeScanEngine(.gated)
        let vm = ScanViewModel { counter.bump(); return engine }
        vm.startScan()
        vm.startScan()
        await until("scanning") { vm.phase == .scanning }
        vm.startScan()
        XCTAssertEqual(counter.value, 1)
        XCTAssertEqual(vm.scanGeneration, 1)
        await engine.send(.finished(F.result([])))
        await until("finished") { vm.phase == .finished }
    }

    func testGenerationIncrementsAndItemsClearedAtStart() async {
        let a = F.item("a")
        let vm = ScanViewModel { FakeScanEngine(.scripted([.finished(F.result([a]))])) }
        vm.startScan()
        await until("finished") { vm.phase == .finished }
        XCTAssertEqual(vm.items.count, 1)
        vm.startScan()
        XCTAssertEqual(vm.scanGeneration, 2)
        XCTAssertTrue(vm.items.isEmpty)
        XCTAssertNil(vm.result)
        await until("finished again") { vm.phase == .finished }
    }

    func testRemoveItemsUpdatesTotals() async {
        let a = F.item("a", size: 300), b = F.item("b", size: 200)
        let vm = ScanViewModel { FakeScanEngine(.scripted([.finished(F.result([a, b]))])) }
        vm.startScan()
        await until("finished") { vm.phase == .finished }
        vm.removeItems([a.id])
        XCTAssertEqual(vm.items, [b])
        XCTAssertEqual(vm.totals.all.allocatedBytes, 200)
        XCTAssertEqual(vm.result?.items, [b])
        XCTAssertNil(vm.item(id: a.id))
    }

    func testCancelDuringStartingEndsCancelledAndCancelsEngineOnce() async {
        let engine = FakeScanEngine(.gated)
        let gate = DispatchSemaphore(value: 0)
        let vm = ScanViewModel { gate.wait(); return engine }
        vm.startScan()
        XCTAssertEqual(vm.phase, .starting)
        vm.cancelScan()
        XCTAssertEqual(vm.phase, .cancelling)
        gate.signal()
        await until("cancelled") { vm.phase == .cancelled }
        let calls = await engine.cancelCalls
        // The build is cancelled with the scan: if it had not begun, no engine exists to cancel (0); if it had, exactly once.
        XCTAssertLessThanOrEqual(calls, 1)
    }

    /// #92: the off-main engine build is cancelled by cancel-while-starting, by a superseding start and by releasing the model.
    private final class BuildProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var observed: [Bool] = []
        let gate = DispatchSemaphore(value: 0)
        let started = DispatchSemaphore(value: 0)
        var cancelledFlags: [Bool] { lock.lock(); defer { lock.unlock() }; return observed }
        func make() -> any ScanEngineProtocol {
            started.signal(); gate.wait()
            lock.lock(); observed.append(Task.isCancelled); lock.unlock()
            return FakeScanEngine(.gated)
        }
    }

    func testCancelWhileStartingCancelsTheBuild() async {
        let probe = BuildProbe()
        let vm = ScanViewModel { probe.make() }
        vm.startScan()
        probe.started.wait()
        vm.cancelScan()
        probe.gate.signal()
        await until("cancelled") { vm.phase == .cancelled }
        XCTAssertEqual(probe.cancelledFlags, [true])
    }

    func testReleasingTheModelCancelsTheBuild() async {
        let probe = BuildProbe()
        var vm: ScanViewModel? = ScanViewModel { probe.make() }
        vm?.startScan()
        probe.started.wait()
        vm = nil
        probe.gate.signal()
        for _ in 0..<400 where probe.cancelledFlags.isEmpty { try? await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(probe.cancelledFlags, [true])
    }

    func testProgressFlushesAreCoalesced() async {
        let engine = FakeScanEngine(.gated)
        let vm = ScanViewModel { engine }
        vm.startScan()
        await until("scanning") { vm.phase == .scanning }
        await engine.send(.itemFound(F.item("a")))
        await engine.send(.progress(F.progress(found: 1)))      // flushes (first)
        await until("flush") { vm.items.count == 1 }
        await engine.send(.itemFound(F.item("b")))
        await engine.send(.progress(F.progress(found: 2)))      // within 200 ms: coalesced
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(vm.items.count, 1)
        await engine.send(.finished(F.result([F.item("a"), F.item("b")])))
        await until("finished") { vm.phase == .finished }
        XCTAssertEqual(vm.items.count, 2)
    }

    func testLargeScanStaysBoundedAndCancelDrainsFast() async {
        let n = 20_000
        let all = (0..<n).map { F.item("item\($0)", tool: ToolID(rawValue: "tool-\($0 % 20)"), size: Int64($0 + 1)) }
        var events: [ScanEvent] = []
        for (i, item) in all.enumerated() {
            events.append(.itemFound(item))
            if i % 10 == 0 { events.append(.progress(F.progress(found: i + 1))) }
        }
        events.append(.finished(F.result(all)))
        let vm = ScanViewModel { FakeScanEngine(.scripted(events)) }
        let start = ContinuousClock.now
        vm.startScan()
        await until("finished") { vm.phase == .finished }
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(5))
        XCTAssertEqual(vm.items.count, n)
        XCTAssertEqual(vm.totals.all.itemCount, n)
        XCTAssertEqual(vm.totals.byTool.count, 20)
        XCTAssertEqual(vm.item(id: all[12_345].id)?.displayName, "item12345")

        // Cancel drains: the backlog is skipped, not re-rendered.
        let engine = FakeScanEngine(.gated)
        let vm2 = ScanViewModel { engine }
        vm2.startScan()
        await until("scanning") { vm2.phase == .scanning }
        for item in all { await engine.send(.itemFound(item)); }
        vm2.cancelScan()
        let t0 = ContinuousClock.now
        await until("cancelled") { vm2.phase == .cancelled }
        XCTAssertLessThan(ContinuousClock.now - t0, .seconds(2))
        XCTAssertEqual(vm2.items.count, n)
    }

    func testQueryOver20kIsFast() {
        let all = (0..<20_000).map { F.item("item\($0)", size: Int64($0)) }
        let t0 = ContinuousClock.now
        _ = ItemQuery(sort: ItemSort(key: .name)).apply(to: all)
        _ = ItemQuery(searchText: "item1").apply(to: all)
        XCTAssertLessThan(ContinuousClock.now - t0, .seconds(3))
    }

    func testFactoryRunsOffMainThread() async {
        let flag = Counter()
        let vm = ScanViewModel {
            if !Thread.isMainThread { flag.bump() }
            return FakeScanEngine(.scripted([.finished(F.result([]))]))
        }
        vm.startScan()
        await until("finished") { vm.phase == .finished }
        XCTAssertEqual(flag.value, 1)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func bump() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}
