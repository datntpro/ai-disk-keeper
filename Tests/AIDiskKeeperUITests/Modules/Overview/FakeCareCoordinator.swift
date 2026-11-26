@testable import DiskKeeperCore
import Foundation
@testable import AIDiskKeeperUI

/// Test double for the Care Scan. The test pushes `CareScanEvent`s; `cancel()` ends the stream with `.cancelled`
/// like the real coordinator. Never touches the disk.
actor FakeCareCoordinator: CareScanning {
    private var continuation: AsyncStream<CareScanEvent>.Continuation?
    private(set) var scanCalls = 0
    private(set) var cancelCalls = 0

    func scan() async throws -> AsyncStream<CareScanEvent> {
        scanCalls += 1
        let (stream, cont) = AsyncStream.makeStream(of: CareScanEvent.self, bufferingPolicy: .unbounded)
        continuation = cont
        return stream
    }

    func send(_ events: CareScanEvent...) {
        for event in events {
            continuation?.yield(event)
            switch event {
            case .finished, .cancelled: continuation?.finish()
            default: break
            }
        }
    }

    func cancel() async {
        cancelCalls += 1
        continuation?.yield(.cancelled(CareFix.report(cancelled: true)))
        continuation?.finish()
    }

    var isScanning: Bool { continuation != nil }
}

enum CareFix {
    static let allStages: [CareStage] = [.rules, .index, .largeOld, .duplicates, .apps, .startup]

    static let ruleStarted = ScanEvent.started(id: UUID(), startedAt: ItemFixtures.t0, scannerIDs: [])

    static func totals(safe: Int64 = 0, review: Int64 = 0, keep: Int64 = 0) -> CareTotals {
        var t = CareTotals()
        t.safeBytes = safe; t.reviewBytes = review; t.keepBytes = keep
        return t
    }

    static func report(safe: Int64 = 0, review: Int64 = 0, keep: Int64 = 0, cancelled: Bool = false,
                       summaries: [CareModule: ModuleSummary] = [:], failed: [CareStage] = [],
                       growth: CareGrowth? = nil) -> CareReport {
        CareReport(id: UUID(), startedAt: ItemFixtures.t0, finishedAt: ItemFixtures.t0.addingTimeInterval(5),
                   wasCancelled: cancelled, summaries: summaries, totals: totals(safe: safe, review: review, keep: keep),
                   warnings: [], failedStages: failed, growth: growth)
    }

    static func started(_ stages: [CareStage] = allStages) -> CareScanEvent {
        .started(id: UUID(), stages: stages, at: ItemFixtures.t0)
    }
}

/// Everything a Care Scan model test needs, wired to fakes.
@MainActor
final class CareRig {
    let coordinator = FakeCareCoordinator()
    let scan = ScanViewModel(makeEngine: { FakeScanEngine(.scripted([])) })
    let fakeIndexer = FakeDiskIndexer()
    let index: DiskIndexModel
    let model: CareScanModel
    var announcements: [String] = []
    var duplicates: DuplicatesModel?
    var largeOld: LargeOldModel?

    init() {
        let fake = fakeIndexer
        index = DiskIndexModel(makeIndexer: { fake }, fullDiskAccess: { false })
        let coordinator = coordinator
        var sink: ((String) -> Void)?
        var dupes: (() -> DuplicatesModel?)?
        var large: (() -> LargeOldModel?)?
        model = CareScanModel(makeCoordinator: { _ in coordinator }, scan: scan, index: index,
                              duplicates: { dupes?() }, largeOld: { large?() }, announce: { sink?($0) })
        sink = { [unowned self] in announcements.append($0) }
        dupes = { [unowned self] in duplicates }
        large = { [unowned self] in largeOld }
    }

    func waitUntil(_ cond: @MainActor () async -> Bool) async {
        for _ in 0..<800 { if await cond() { return }; try? await Task.sleep(nanoseconds: 5_000_000) }
    }

    /// Starts the scan and waits until the fake has been asked to scan.
    func begin() async {
        model.start()
        await waitUntil { await self.coordinator.isScanning }
    }

    func send(_ events: CareScanEvent...) async {
        for e in events { await coordinator.send(e) }
    }

    func settle() async { try? await Task.sleep(nanoseconds: 60_000_000) }
}

/// Like the real coordinator, `cancel()` is ignored until `scan()` has returned; `scan()` waits for `open()`.
actor GatedCareCoordinator: CareScanning {
    private var gate: CheckedContinuation<Void, Never>?
    private var opened = false
    private var continuation: AsyncStream<CareScanEvent>.Continuation?
    private(set) var cancelCalls = 0
    private(set) var ignoredCancels = 0
    private(set) var isWaiting = false

    func scan() async throws -> AsyncStream<CareScanEvent> {
        if !opened { isWaiting = true; await withCheckedContinuation { gate = $0 } }
        let (stream, cont) = AsyncStream.makeStream(of: CareScanEvent.self, bufferingPolicy: .unbounded)
        continuation = cont
        return stream
    }

    func open() { opened = true; gate?.resume(); gate = nil }

    func cancel() async {
        cancelCalls += 1
        guard let continuation else { ignoredCancels += 1; return }
        continuation.yield(.cancelled(CareFix.report(cancelled: true)))
        continuation.finish()
    }
}
