import Darwin
import Foundation
import XCTest
@testable import DiskKeeperCore

final class DuplicateFinderCancellationTests: XCTestCase {
    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var task: Task<DuplicateReport, Error>?
        private var cancelledAt: ContinuousClock.Instant?
        func set(_ t: Task<DuplicateReport, Error>) { lock.lock(); task = t; lock.unlock() }
        func cancelOnce() {
            lock.lock(); defer { lock.unlock() }
            guard cancelledAt == nil, let task else { return }
            cancelledAt = .now
            task.cancel()
        }
        var at: ContinuousClock.Instant? { lock.lock(); defer { lock.unlock() }; return cancelledAt }
    }

    /// The plan asks for 200 files × 20 MB in 100 groups (4 GB). That is `ADK_BENCH=1`; the default run uses
    /// 60 files × 8 MB in 30 groups, which is still hundreds of read chunks to interrupt.
    func testCancelDuringFullHashStopsFastAndLeaksNoDescriptors() async throws {
        let big = ProcessInfo.processInfo.environment["ADK_BENCH"] == "1"
        let groups = big ? 100 : 30, size = big ? 20 << 20 : 8 << 20
        let need = Int64(groups * 2 * size) * 3 / 2
        let tmp = FileManager.default.temporaryDirectory.path
        var fs = statfs(); statfs(tmp, &fs)
        guard Int64(fs.f_bavail) * Int64(fs.f_bsize) > need + (2 << 30) else { throw XCTSkip("not enough free disk") }

        let fx = try FixtureHome()
        for g in 0..<groups {
            let d = DupFix.data(seed: UInt64(g + 1), count: size)
            try DupFix.write(fx.abs("g\(g)/a"), d); try DupFix.write(fx.abs("g\(g)/b"), d)
        }
        let tree = try await IndexTest.index(fx)
        let before = DupFix.openFDCount()
        let box = Box()
        let options = DupFix.options(fx)
        let task = Task<DuplicateReport, Error> {
            try await DuplicateFinder(options: options).find(in: tree) { stats in
                if stats.fullHashed >= 1 { box.cancelOnce() }
            }
        }
        box.set(task)
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
            let end = ContinuousClock.now
            let start = try XCTUnwrap(box.at)
            XCTAssertLessThan(start.duration(to: end), .milliseconds(200))
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(DupFix.openFDCount(), before, "file descriptors leaked")
    }
}
