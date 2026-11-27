import Darwin
import Foundation
import XCTest
@testable import DiskKeeperCore

/// 200k-file incremental scan benchmark (T25). Opt-in: `ADK_BENCH=1 swift test --filter Benchmark`.
/// Skipped in the normal test job so default `swift test` never generates 200k files.
/// Writes `BENCH ...` lines to stdout and, when `ADK_BENCH_OUT` is a file path, appends them there too.
final class IncrementalScanBenchmarkTests: XCTestCase {
    private static var enabled: Bool { ProcessInfo.processInfo.environment["ADK_BENCH"] == "1" }
    private static let itemCount = 50
    private static let dirsPerItem = 40            // 2,000 directories
    private static let filesPerDir = 100           // 200,000 files

    nonisolated(unsafe) private static var fixture: TemporaryDirectory?

    override class func tearDown() {
        fixture?.cleanup()
        fixture = nil
        super.tearDown()
    }

    /// ≈2k dirs, depth ≤ 8, 200k files of 0–64 KiB (sparse: the walk cost is what is measured, not the disk writes).
    /// Generated once per run and reused by every test in this class.
    private func fixtureRoot() throws -> URL {
        if let f = Self.fixture { return f.url }
        let tmp = try TemporaryDirectory()
        Self.fixture = tmp
        var rng = SplitMix(seed: 42)
        for i in 0..<Self.itemCount {
            for d in 0..<Self.dirsPerItem {
                let depth = 1 + Int(rng.next() % 7)
                let rel = "t\(i)/" + (0..<depth).map { "d\($0)" }.joined(separator: "/") + "/leaf\(d)"
                let dir = tmp.url.appendingPathComponent(rel)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                for f in 0..<Self.filesPerDir {
                    let fd = open(dir.appendingPathComponent("f\(f)").path, O_WRONLY | O_CREAT, 0o644)
                    guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                    ftruncate(fd, off_t(rng.next() % 65_537))
                    close(fd)
                }
            }
        }
        return tmp.url
    }

    private func report(_ line: String) {
        var loadavg = [Double](repeating: 0, count: 3)
        getloadavg(&loadavg, 3)
        let full = "BENCH \(line) (loadavg1=\(String(format: "%.2f", loadavg[0])), ncpu=\(ProcessInfo.processInfo.activeProcessorCount))"
        print(full)
        if let out = ProcessInfo.processInfo.environment["ADK_BENCH_OUT"], let h = FileHandle(forWritingAtPath: out)
            ?? (FileManager.default.createFile(atPath: out, contents: nil) ? FileHandle(forWritingAtPath: out) : nil) {
            h.seekToEndOfFile(); h.write(Data((full + "\n").utf8)); try? h.close()
        }
    }

    private func scanAll(root: URL, cache: SizeCache?, concurrency: Int) async throws -> TimeInterval {
        let env = PathEnvironment(home: root.path, temporaryDirectory: root.path, variables: [:])
        let ctx = ScanContext(environment: env, pathGuard: try ScanGuard(environment: env, protectPatterns: []),
                              maxConcurrentSizing: concurrency, sizeCache: cache)
        let t0 = ContinuousClock.now
        await cache?.beginScan(options: ctx.sizerOptions)
        try await withThrowingTaskGroup(of: Void.self) { group in
            var next = 0
            func start() {
                guard next < Self.itemCount else { return }
                let u = root.appendingPathComponent("t\(next)"); next += 1
                group.addTask { _ = try await ctx.size(u) }
            }
            for _ in 0..<concurrency { start() }
            while try await group.next() != nil { start() }
        }
        await cache?.endScan()
        let d = t0.duration(to: .now)
        return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }

    func testSecondScanIsAtLeast3xFaster() async throws {
        try XCTSkipUnless(Self.enabled, "set ADK_BENCH=1")
        guard SizeCache.dataVolumeDevice() != nil else { throw XCTSkip("no Data volume") }
        let root = try fixtureRoot()
        let cacheFile = root.deletingLastPathComponent().appendingPathComponent("adk-bench-cache-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: cacheFile) }
        let cold = try await scanAll(root: root, cache: SizeCache(fileURL: cacheFile),
                                     concurrency: ScanContext.defaultConcurrentSizing)
        let warmCache = SizeCache(fileURL: cacheFile)        // a new process in spirit: loads the file, asks the journal
        let warm = try await scanAll(root: root, cache: warmCache, concurrency: ScanContext.defaultConcurrentSizing)
        let hits = await warmCache.hits
        report("incremental files=200000 cold=\(String(format: "%.3f", cold))s warm=\(String(format: "%.3f", warm))s "
               + "speedup=\(String(format: "%.1f", cold / max(warm, 1e-6)))x warmHits=\(hits)/\(Self.itemCount)")
        XCTAssertEqual(hits, Self.itemCount, "an untouched tree must be served entirely from the cache")
        XCTAssertGreaterThanOrEqual(cold / warm, 3.0, "second scan must be ≥ 3× faster than the first")
    }

    /// Measures `maxConcurrentSizing` on the 200k fixture (cold, no cache). The default is set from this table.
    func testConcurrencyTable() async throws {
        try XCTSkipUnless(Self.enabled, "set ADK_BENCH=1")
        let root = try fixtureRoot()
        _ = try await scanAll(root: root, cache: nil, concurrency: 4)   // warm the page cache; not reported
        let ncpu = ProcessInfo.processInfo.activeProcessorCount
        for n in Array(Set([2, 4, 8, ncpu])).sorted() {
            var times: [Double] = []
            for _ in 0..<3 { times.append(try await scanAll(root: root, cache: nil, concurrency: n)) }
            report("concurrency n=\(n) best=\(String(format: "%.3f", times.min()!))s median=\(String(format: "%.3f", times.sorted()[1]))s")
        }
    }
}

private struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
