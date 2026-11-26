import DiskKeeperCore
import Foundation
import XCTest
@testable import DiskKeeperCore
@testable import AIDiskKeeperUI

/// Hands out the pre-built fakes in order, one per `makeIndexer()` call.
private final class IndexerSource: @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [FakeDiskIndexer]
    init(_ fakes: [FakeDiskIndexer]) { queue = fakes }
    func next() throws -> any DiskIndexing {
        lock.lock(); defer { lock.unlock() }
        return queue.removeFirst()
    }
}

@MainActor
final class DiskIndexModelTests: XCTestCase {
    private struct Boom: Error, CustomStringConvertible { var description: String { "boom" } }

    private func waitUntil(_ cond: @MainActor () async -> Bool) async {
        for _ in 0..<600 { if await cond() { return }; try? await Task.sleep(nanoseconds: 5_000_000) }
    }

    private func make(_ fakes: [FakeDiskIndexer], fda: Bool = false,
                      interval: Duration = .milliseconds(100)) -> DiskIndexModel {
        let source = IndexerSource(fakes)
        return DiskIndexModel(makeIndexer: { try source.next() }, fullDiskAccess: { fda }, minProgressInterval: interval)
    }

    func testIdleToIndexingToReady() async {
        let fake = FakeDiskIndexer()
        let m = make([fake])
        XCTAssertEqual(m.phase, .idle)
        XCTAssertNil(m.tree)
        m.start(.home)
        XCTAssertEqual(m.phase, .indexing)
        await waitUntil { await fake.isWaiting }
        await fake.finish(FakeDiskIndexer.tree())
        await waitUntil { m.phase == .ready }
        XCTAssertEqual(m.phase, .ready)
        XCTAssertNotNil(m.tree)
        XCTAssertEqual(m.generation, 1)
        XCTAssertNotNil(m.builtAt)
        XCTAssertNil(m.progress)
    }

    func testGenerationIncrementsPerTree() async {
        let a = FakeDiskIndexer(), b = FakeDiskIndexer()
        let m = make([a, b])
        m.start(.home)
        await waitUntil { await a.isWaiting }
        await a.finish(FakeDiskIndexer.tree())
        await waitUntil { m.phase == .ready }
        m.start(.home)
        XCTAssertNotNil(m.tree, "the old tree stays while re-indexing")
        await waitUntil { await b.isWaiting }
        await b.finish(FakeDiskIndexer.tree("b"))
        await waitUntil { m.generation == 2 }
        XCTAssertEqual(m.generation, 2)
    }

    func testCancelKeepsOldTree() async {
        let a = FakeDiskIndexer(), b = FakeDiskIndexer()
        let m = make([a, b])
        m.start(.home)
        await waitUntil { await a.isWaiting }
        await a.finish(FakeDiskIndexer.tree())
        await waitUntil { m.phase == .ready }
        let old = m.tree
        m.start(.home)
        await waitUntil { await b.isWaiting }
        m.cancel()
        XCTAssertEqual(m.phase, .cancelled)
        await waitUntil { await b.cancelCalls > 0 }
        let cancels = await b.cancelCalls
        XCTAssertGreaterThan(cancels, 0)
        XCTAssertEqual(m.phase, .cancelled)
        XCTAssertEqual(m.generation, 1)
        XCTAssertEqual(m.tree?.rootPath, old?.rootPath)
    }

    func testFailureKeepsOldTree() async {
        let a = FakeDiskIndexer(), b = FakeDiskIndexer()
        let m = make([a, b])
        m.start(.home)
        await waitUntil { await a.isWaiting }
        await a.finish(FakeDiskIndexer.tree())
        await waitUntil { m.phase == .ready }
        m.start(.home)
        await waitUntil { await b.isWaiting }
        await b.fail(Boom())
        await waitUntil { m.phase != .indexing }
        XCTAssertEqual(m.phase, .failed("boom"))
        XCTAssertNotNil(m.tree)
        XCTAssertEqual(m.generation, 1)
    }

    func testFullDiskWithoutAccessIsRefused() async {
        let fake = FakeDiskIndexer()
        let m = make([fake], fda: false)
        m.start(.fullDisk)
        XCTAssertEqual(m.phase, .idle)
        XCTAssertEqual(m.scope, .home)
        let scopes = await fake.scopes
        XCTAssertTrue(scopes.isEmpty)
        XCTAssertFalse(m.fullDiskAvailable)
    }

    func testFullDiskWithAccessStarts() async {
        let fake = FakeDiskIndexer()
        let m = make([fake], fda: true)
        m.start(.fullDisk)
        XCTAssertEqual(m.phase, .indexing)
        XCTAssertEqual(m.scope, .fullDisk)
        await waitUntil { await fake.isWaiting }
        let scopes = await fake.scopes
        XCTAssertEqual(scopes, [.fullDisk])
        m.cancel()
    }

    func testSecondStartCancelsTheFirst() async {
        let a = FakeDiskIndexer(), b = FakeDiskIndexer()
        let m = make([a, b])
        m.start(.home)
        await waitUntil { await a.isWaiting }
        m.start(.folder("/tmp/x"))
        await waitUntil { await b.isWaiting }
        await waitUntil { await a.cancelCalls > 0 }
        let cancelled = await a.cancelCalls
        XCTAssertGreaterThan(cancelled, 0)
        XCTAssertEqual(m.phase, .indexing, "the first run's cancellation must not end the second")
        XCTAssertEqual(m.scope, .folder("/tmp/x"))
        await b.finish(FakeDiskIndexer.tree("second"))
        await waitUntil { m.phase == .ready }
        XCTAssertEqual(m.generation, 1)
    }

    func testProgressIsCoalesced() async {
        let fake = FakeDiskIndexer()
        await fake.setProgressBurst((1...50).map { IndexProgress(entriesVisited: $0, directoriesVisited: 1, allocatedBytesSoFar: 1) })
        let m = make([fake], interval: .seconds(60))
        m.start(.home)
        await waitUntil { await fake.isWaiting }
        await waitUntil { m.progress != nil }
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(m.appliedProgressCount, 1)
        m.cancel()
    }

    func testMakeIndexerFailureBecomesFailedPhase() async {
        let m = DiskIndexModel(makeIndexer: { throw Boom() }, fullDiskAccess: { false })
        m.start(.home)
        await waitUntil { m.phase != .indexing }
        XCTAssertEqual(m.phase, .failed("boom"))
        XCTAssertNil(m.tree)
    }
}
