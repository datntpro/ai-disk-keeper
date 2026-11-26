import Foundation
import XCTest
@testable import DiskKeeperCore

/// `ADK_BENCH=1 swift test --filter DuplicateBenchmarkTests`. Target: ≥ 1 GB/s full-hash throughput on an
/// M-series internal SSD with 4 concurrent jobs (cold cache is not forced; see docs/duplicates.md).
final class DuplicateBenchmarkTests: XCTestCase {
    func testTenThousandCandidates() async throws {
        guard ProcessInfo.processInfo.environment["ADK_BENCH"] == "1" else { throw XCTSkip("set ADK_BENCH=1") }
        let fx = try FixtureHome()
        var total: Int64 = 0
        var rng = SystemRandomNumberGenerator()
        let unique = 7_000
        for i in 0..<unique {
            let size = 1_000_000 + Int.random(in: 0..<500_000, using: &rng)
            let d = DupFix.data(seed: UInt64(i + 1), count: size)
            try DupFix.write(fx.abs("d\(i % 100)/u\(i)"), d)
            total += Int64(size)
            if i % 7 < 3 {   // 30% of the files get a copy: ~3000 duplicates
                try DupFix.write(fx.abs("d\((i + 1) % 100)/c\(i)"), d)
                total += Int64(size)
            }
        }
        let tree = try await IndexTest.index(fx)
        let report = try await DuplicateFinder(options: DupFix.options(fx)).find(in: tree)
        let s = report.stats
        let secs = Double(s.duration.components.seconds) + Double(s.duration.components.attoseconds) / 1e18
        print("""
        DUPLICATE BENCHMARK
          candidates \(s.candidates), buckets \(s.sizeBuckets), partial \(s.partialHashed), full \(s.fullHashed)
          groups \(report.groups.count), bytes on disk \(total / 1_000_000) MB, bytes read \(s.bytesRead / 1_000_000) MB
          wall \(String(format: "%.2f", secs)) s, throughput \(String(format: "%.0f", Double(s.bytesRead) / 1e6 / secs)) MB/s
        """)
        XCTAssertGreaterThan(report.groups.count, 0)
    }
}
