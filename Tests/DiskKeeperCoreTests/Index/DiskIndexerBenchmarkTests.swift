import Darwin
import Foundation
import XCTest
@testable import DiskKeeperCore

/// Opt-in: `ADK_BENCH=1` (synthetic tree); also `ADK_BENCH_REAL_HOME=1` for the real home (read-only).
final class DiskIndexerBenchmarkTests: XCTestCase {
    private func peakRSSMB() -> Double {
        var u = rusage(); getrusage(RUSAGE_SELF, &u)
        return Double(u.ru_maxrss) / 1_048_576
    }

    private func secs(_ d: Duration) -> Double { Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18 }

    private func bench(label: String, root: String, env: PathEnvironment, guardPaths: ProtectedPaths, exact: Bool) async throws {
        let clock = ContinuousClock()
        let t0 = clock.now
        let report = try FileSizer().sizeBlocking(of: URL(fileURLWithPath: root))
        let sizerSecs = secs(t0.duration(to: clock.now))
        let rssBefore = peakRSSMB()
        let t1 = clock.now
        let tree = try await DiskIndexer(environment: env, pathGuard: guardPaths).index(.folder(root))
        let indexSecs = secs(t1.duration(to: clock.now))
        print("""
        BENCH \(label): entries=\(tree.stats.entriesVisited) sizer=\(String(format: "%.2f", sizerSecs))s \
        index=\(String(format: "%.2f", indexSecs))s ratio=\(String(format: "%.2f", indexSecs / max(sizerSecs, 0.001))) \
        entries/s=\(Int(Double(tree.stats.entriesVisited) / max(indexSecs, 0.001))) nodes=\(tree.nodeCount) \
        records=\(tree.fileRecords.count) treeMB=\(tree.estimatedMemoryBytes / 1_048_576) \
        peakRSS_MB(before→after)=\(Int(rssBefore))→\(Int(peakRSSMB())) complete=\(tree.stats.isComplete) issues=\(tree.stats.issueCount)
        """)
        let diff = tree.node(tree.root).allocatedBytes - report.allocatedBytes
        print("BENCH \(label): allocated diff vs FileSizer = \(diff) bytes")
        if exact { XCTAssertEqual(diff, 0) }   // a live home changes between the two runs
    }

    func testBenchmarkSynthetic() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ADK_BENCH"] == "1", "set ADK_BENCH=1")
        let fx = try FixtureHome()
        for d in 0..<2000 {
            let dir = fx.home + "/d\(d % 40)/s\(d / 40)/sub"
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            for f in 0..<100 { FileManager.default.createFile(atPath: dir + "/f\(f)", contents: Data(count: 200)) }
        }
        try await bench(label: "synthetic-200k", root: fx.home, env: fx.env,
                        guardPaths: try ProtectedPaths(homeDirectory: fx.home, temporaryDirectory: fx.tempDir), exact: true)
    }

    func testBenchmarkRealHome() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ADK_BENCH_REAL_HOME"] == "1", "set ADK_BENCH_REAL_HOME=1")
        let home = NSHomeDirectory()
        let env = PathEnvironment(home: home, temporaryDirectory: NSTemporaryDirectory(), variables: [:])
        let g = try ProtectedPaths(homeDirectory: home, temporaryDirectory: NSTemporaryDirectory())
        try await bench(label: "real-home", root: home, env: env, guardPaths: g, exact: false)
    }
}
