import XCTest
@testable import DiskKeeperCore

private final class FakeTable: ProcessTableReading, @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [ProcessTableSnapshot]
    init(_ snaps: [ProcessTableSnapshot]) { queue = snaps }
    func snapshot() -> ProcessTableSnapshot? {
        lock.lock(); defer { lock.unlock() }
        return queue.isEmpty ? nil : queue.removeFirst()
    }
}

private final class FakeDisk: DiskStatisticsReading, @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [DiskStatistics]
    init(_ q: [DiskStatistics]) { queue = q }
    func read() -> DiskStatistics? {
        lock.lock(); defer { lock.unlock() }
        return queue.isEmpty ? nil : queue.removeFirst()
    }
}

private final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    private let base = ContinuousClock.now
    func next() -> ContinuousClock.Instant { lock.lock(); defer { lock.unlock() }; defer { n += 5 }; return base + .seconds(n) }
}

final class HostLoadSamplerTests: XCTestCase {
    private var tmp: TemporaryDirectory!
    override func setUpWithError() throws { tmp = try TemporaryDirectory() }
    override func tearDown() { tmp = nil }

    private func proc(_ pid: pid_t, _ ppid: pid_t, _ name: String, cwd: String?, written: UInt64) -> ProcessRecord {
        ProcessRecord(pid: pid, ppid: ppid, name: name, cwd: cwd, startID: 1, diskBytesWritten: written)
    }

    func testWorktreeAndAgentSumsAndUnattributed() async throws {
        try FileManager.default.createDirectory(atPath: tmp.path("wt1/.git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: tmp.path("wt2/.git"), withIntermediateDirectories: true)
        let wt1 = tmp.path("wt1"), wt2 = tmp.path("wt2")
        let t0 = ContinuousClock.now
        func snap(_ s: Int, _ w: [UInt64]) -> ProcessTableSnapshot {
            ProcessTableSnapshot(at: t0 + .seconds(s), wall: Date(), records: [
                proc(1, 0, "claude", cwd: wt1, written: w[0]),
                proc(2, 1, "node", cwd: wt1, written: w[1]),
                proc(3, 0, "dd", cwd: wt2, written: w[2]),
                proc(4, 0, "mdworker_shared", cwd: "/", written: w[3]),
            ])
        }
        let table = FakeTable([snap(0, [0, 0, 0, 0]), snap(5, [5_000, 10_000, 20_000, 5_000])])
        let disk = FakeDisk([
            DiskStatistics(bytesRead: 0, bytesWritten: 0, totalTimeReadNs: 0, totalTimeWriteNs: 0),
            DiskStatistics(bytesRead: 0, bytesWritten: 200_000, totalTimeReadNs: 0, totalTimeWriteNs: 1_000_000_000),
        ])
        let clock = FakeClock()
        let sampler = HostLoadSampler(table: table, disk: disk, attribution: WorktreeAttribution(home: tmp.url.path),
                                      clock: { clock.next() })
        let first = await sampler.tick()
        XCTAssertTrue(first.processes.isEmpty)
        XCTAssertNil(first.disk)
        let s = await sampler.tick()
        XCTAssertEqual(s.processes.count, 4)
        let attributedTotal = s.processes.reduce(0) { $0 + $1.writeBytesPerSec }
        XCTAssertEqual(attributedTotal, 8_000, accuracy: 0.01)
        let byWt = Dictionary(uniqueKeysWithValues: s.byWorktree.map { ($0.worktree.root, $0) })
        XCTAssertEqual(byWt[wt1]?.writeBytesPerSec ?? 0, 3_000, accuracy: 0.01)
        XCTAssertEqual(byWt[wt2]?.writeBytesPerSec ?? 0, 4_000, accuracy: 0.01)
        XCTAssertEqual(byWt[wt1]?.processCount, 2)
        XCTAssertEqual(byWt[wt1]?.agents, [.claude])
        XCTAssertEqual(s.byWorktree.first?.worktree.root, wt2, "sorted by write rate")
        XCTAssertEqual(s.byWorktree.reduce(0) { $0 + $1.writeBytesPerSec }, 7_000, accuracy: 0.01,
                       "worktree rows sum to the attributed processes (spotlight has no worktree)")
        let byAgent = Dictionary(uniqueKeysWithValues: s.byAgent.map { ($0.kind, $0) })
        XCTAssertEqual(byAgent[.claude]?.writeBytesPerSec ?? 0, 3_000, accuracy: 0.01, "node under claude counts for claude")
        XCTAssertEqual(byAgent[.spotlight]?.writeBytesPerSec ?? 0, 1_000, accuracy: 0.01)
        XCTAssertEqual(byAgent[.other]?.writeBytesPerSec ?? 0, 4_000, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(s.unattributedWriteBytesPerSec), 40_000 - 8_000, accuracy: 0.01)
        XCTAssertEqual(s.processes.first?.name, "dd")
    }

    func testUnattributedNeverNegative() async {
        let t0 = ContinuousClock.now
        func snap(_ s: Int, _ w: UInt64) -> ProcessTableSnapshot {
            ProcessTableSnapshot(at: t0 + .seconds(s), wall: Date(), records: [proc(1, 0, "dd", cwd: nil, written: w)])
        }
        let clock2 = FakeClock()
        let sampler = HostLoadSampler(
            table: FakeTable([snap(0, 0), snap(5, 500_000)]),
            disk: FakeDisk([DiskStatistics(bytesRead: 0, bytesWritten: 0, totalTimeReadNs: 0, totalTimeWriteNs: 0),
                            DiskStatistics(bytesRead: 0, bytesWritten: 1_000, totalTimeReadNs: 0, totalTimeWriteNs: 0)]),
            attribution: WorktreeAttribution(home: tmp.url.path), clock: { clock2.next() })
        _ = await sampler.tick()
        let s = await sampler.tick()
        XCTAssertEqual(s.unattributedWriteBytesPerSec, 0)
    }

    func testNoDiskReadingMeansNoUnattributed() async {
        let sampler = HostLoadSampler(table: FakeTable([]), disk: FakeDisk([]), attribution: WorktreeAttribution(home: tmp.url.path))
        let s = await sampler.tick()
        XCTAssertNil(s.disk)
        XCTAssertNil(s.unattributedWriteBytesPerSec)
        XCTAssertTrue(s.processes.isEmpty)
    }
}
