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
