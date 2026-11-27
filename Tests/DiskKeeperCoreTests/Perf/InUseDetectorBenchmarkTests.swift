import Darwin
import XCTest
@testable import DiskKeeperCore

/// `ADK_BENCH=1 swift test --filter InUseDetectorBenchmarkTests`. Reads the real process table of the machine it
/// runs on (read-only), so it is skipped everywhere else.
final class InUseDetectorBenchmarkTests: XCTestCase {
    func testSnapshotAndIndexOfAllProcessesUnderTwoSeconds() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ADK_BENCH"] == "1", "set ADK_BENCH=1")
        let started = ContinuousClock.now
        let holds = try XCTUnwrap(LibprocUsageSource().snapshot(userID: getuid()))
        let snapshotted = ContinuousClock.now
        let index = InUseIndex(holds, currentUID: getuid())
        _ = index.holder(of: "/nonexistent/path")
        let done = ContinuousClock.now
        func ms(_ d: Duration) -> Double { Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15 }
        let files = holds.reduce(0) { $0 + $1.openPaths.count }
        print("T20 bench: \(holds.count) processes, \(files) open paths, snapshot \(Int(ms(snapshotted - started))) ms, index \(Int(ms(done - snapshotted))) ms")
        XCTAssertLessThan(ms(done - started), 2000)
    }
}
