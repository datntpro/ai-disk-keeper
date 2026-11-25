import Foundation
import XCTest
@testable import DiskKeeperCore

/// Opt-in benchmarks; skipped unless env vars are set, so CI never runs them.
final class FileSizerBenchmarkTests: XCTestCase {
    func testBenchmarkSyntheticTree() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DISKKEEPER_BENCH"] == "1",
                          "set DISKKEEPER_BENCH=1")
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
        print("synthetic: \(entries) entries")
    }

    func testBenchmarkRealPaths() throws {
        let raw = try XCTUnwrap(ProcessInfo.processInfo.environment["DISKKEEPER_BENCH_PATHS"],
                                "set DISKKEEPER_BENCH_PATHS")
        let sizer = FileSizer()
        for p in raw.split(separator: ":").map(String.init) {
            let t0 = ContinuousClock.now
            let r = try sizer.sizeBlocking(of: URL(fileURLWithPath: p))
            let secs = Double((t0.duration(to: .now)).components.seconds)
                + Double((t0.duration(to: .now)).components.attoseconds) / 1e18
            let du = Process()
            du.executableURL = URL(fileURLWithPath: "/usr/bin/du")
            du.arguments = ["-sk", p]
            let pipe = Pipe()
            du.standardOutput = pipe
            du.standardError = Pipe()
            try du.run()
            let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            du.waitUntilExit()
            let duKB = out.split(whereSeparator: { $0 == "\t" || $0 == " " }).first.map(String.init) ?? "?"
            print("BENCH \(p), entries=\(r.entriesVisited), allocated=\(r.allocatedBytes / 1024)KB, "
                  + "seconds=\(String(format: "%.3f", secs)), du=\(duKB)KB")
        }
    }
}
