import Foundation
import XCTest
@testable import DiskKeeperCore

/// Opt-in benchmarks (`ADK_BENCH=1`); skipped in the normal test job, run by the non-blocking `bench` CI job.
final class FileSizerBenchmarkTests: XCTestCase {
    func testBenchmarkSyntheticTree() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ADK_BENCH"] == "1",
                          "set ADK_BENCH=1")
        let tmp = try TemporaryDirectory()
        defer { tmp.cleanup() }
        for d in 0..<2000 {
            for f in 0..<25 { try tmp.file("nm/d\(d)/f\(f).js", bytes: 200) }
        }
        let sizer = FileSizer()
        var entries = 0
        measure {
            entries = (try? sizer.sizeBlocking(of: tmp.url.appendingPathComponent("nm")).entriesVisited) ?? 0
        }
        print("synthetic: \(entries) entries (entries/s = entries / measured average above)")
    }

    func testBenchmarkRealPaths() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DISKKEEPER_BENCH_PATHS"] != nil,
                          "set DISKKEEPER_BENCH_PATHS")
        let raw = ProcessInfo.processInfo.environment["DISKKEEPER_BENCH_PATHS"] ?? ""
        let sizer = FileSizer()
        for p in raw.split(separator: ":").map(String.init) {
            let t0 = ContinuousClock.now
            let r = try sizer.sizeBlocking(of: URL(fileURLWithPath: p))
            let d = t0.duration(to: .now)
            let secs = Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
            let t1 = ContinuousClock.now
            let du = Process()
            du.executableURL = URL(fileURLWithPath: "/usr/bin/du")
            du.arguments = ["-sk", p]
            let pipe = Pipe()
            du.standardOutput = pipe
            du.standardError = Pipe()
            try du.run()
            let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            du.waitUntilExit()
            let d2 = t1.duration(to: .now)
            let duSecs = Double(d2.components.seconds) + Double(d2.components.attoseconds) / 1e18
            let duKB = out.split(whereSeparator: { $0 == "\t" || $0 == " " }).first.map(String.init) ?? "?"
            print("BENCH \(p), entries=\(r.entriesVisited), allocated=\(r.allocatedBytes / 1024)KB, "
                  + "seconds=\(String(format: "%.3f", secs)), entries/s=\(Int(Double(r.entriesVisited) / max(secs, 1e-9))), "
                  + "du=\(duKB)KB, du_seconds=\(String(format: "%.3f", duSecs))")
        }
    }
}
