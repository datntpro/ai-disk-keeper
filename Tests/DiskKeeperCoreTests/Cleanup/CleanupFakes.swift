import Darwin
import Foundation
import XCTest
@testable import DiskKeeperCore

/// Moves into a fixture Trash directory as `<uuid>-<name>`.
struct DirectoryTrash: TrashAdapter {
    let root: URL
    func trashItem(at url: URL) throws -> URL? {
        let dest = root.appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)")
        try FileManager.default.moveItem(at: url, to: dest)
        return dest
    }
}

/// Throws on the n-th call (1-based), otherwise delegates.
final class FailingTrash: TrashAdapter, @unchecked Sendable {
    struct Boom: Error {}
    let inner: DirectoryTrash
    let failOn: Int
    private let lock = NSLock()
    private var calls = 0
    init(inner: DirectoryTrash, failOn: Int) { self.inner = inner; self.failOn = failOn }
    func trashItem(at url: URL) throws -> URL? {
        lock.lock(); calls += 1; let n = calls; lock.unlock()
        if n == failOn { throw Boom() }
        return try inner.trashItem(at: url)
    }
}

/// Trashes the real item but reports a different URL.
struct LyingTrash: TrashAdapter {
    let inner: DirectoryTrash
    let reported: URL
    func trashItem(at url: URL) throws -> URL? {
        _ = try inner.trashItem(at: url)
        return reported
    }
}

struct FakeRunningApps: RunningAppChecking {
    let map: [String: Bool]
    init(_ map: [String: Bool] = [:]) { self.map = map }
    func isRunning(bundleID: String) -> Bool? { map[bundleID] ?? false }
}

final class RecordingRemover: ItemRemover, @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []
    var removed: [String] { lock.lock(); defer { lock.unlock() }; return paths }
    func removeItem(atPath path: String) throws {
        lock.lock(); paths.append(path); lock.unlock()
    }
}

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var v = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return v }
    func set() { lock.lock(); v = true; lock.unlock() }
}

final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var t = Date()
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return t }
    func advance(_ s: TimeInterval) { lock.lock(); t = t.addingTimeInterval(s); lock.unlock() }
}

/// Fixture with `home/`, `tmp/`, `Trash/` and `audit/audit.jsonl`.
class CleanupTestCase: XCTestCase {
    var fx: TemporaryDirectory!
    var home: String { fx.path("home") }
    var trashDir: URL { fx.url.appendingPathComponent("Trash") }
    var auditURL: URL { fx.url.appendingPathComponent("audit/audit.jsonl") }

    override func setUpWithError() throws {
        fx = try TemporaryDirectory()
        try fx.dir("home"); try fx.dir("tmp"); try fx.dir("Trash")
    }
    override func tearDown() { fx = nil }

    func makeGuard() throws -> ProtectedPaths {
        try ProtectedPaths(homeDirectory: home, temporaryDirectory: fx.path("tmp"))
    }

    func makeEngine(trash: (any TrashAdapter)? = nil, remover: any ItemRemover = RecordingRemover(),
                    apps: any RunningAppChecking = FakeRunningApps(),
                    options: CleanupOptions = .init(), audit: AuditLog? = nil,
                    now: @escaping @Sendable () -> Date = { Date() }) throws -> CleanupEngine {
        CleanupEngine(pathGuard: try makeGuard(), auditLog: audit ?? AuditLog(fileURL: auditURL),
                      trash: trash ?? DirectoryTrash(root: trashDir), remover: remover,
                      runningApps: apps, options: options, now: now)
    }

    /// Builds a ScanItem from a real FileSizer report of the fixture path.
    func item(_ rel: String, rule: String = "r.test", tier: RiskTier = .safe,
              method: CleanupMethod = .trash, quit: String? = nil) throws -> ScanItem {
        let url = URL(fileURLWithPath: fx.path(rel))
        let r = try FileSizer().sizeBlocking(of: url)
        return ScanItem(url: url, displayName: url.lastPathComponent, tool: .claudeCode, category: .buildArtifact,
                        sizeAllocated: r.allocatedBytes, sizeLogical: r.logicalBytes, fileCount: r.fileCount,
                        lastModified: r.newestModification, tier: tier, explanation: "test", ruleID: rule,
                        cleanupMethod: method, requiresAppQuit: quit)
    }

    func exists(_ rel: String) -> Bool {
        var st = stat()
        return lstat(fx.path(rel), &st) == 0
    }

    func trashContents() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: trashDir.path)) ?? []
    }

    func snapshot() throws -> [String] {
        let e = FileManager.default.enumerator(atPath: fx.url.path)!
        var out: [String] = []
        for case let rel as String in e {
            var st = stat()
            lstat(fx.path(rel), &st)
            out.append("\(rel)|\(st.st_size)|\(st.st_mtimespec.tv_sec)|\(st.st_ino)")
        }
        return out.sorted()
    }

    func skippedCodes(_ o: CleanupOutcome) -> [String] {
        if case .skipped(let b) = o { return b.map(\.code) }
        return []
    }
}


extension CleanupTestCase {
    /// An engine whose audit log is a FIFO: `execute` blocks in `auditLog.open()` (holding the run slot) until a reader opens it.
    func makeFIFOEngine(clock: Clock) throws -> (engine: CleanupEngine, fifo: String) {
        try fx.dir("audit")
        let fifo = fx.path("audit/fifo.jsonl")
        XCTAssertEqual(mkfifo(fifo, 0o600), 0)
        return (try makeEngine(audit: AuditLog(fileURL: URL(fileURLWithPath: fifo)), now: { clock.now() }), fifo)
    }

    /// Deterministic "expires while queued": `first` takes the run slot and parks in the FIFO open, `second` queues behind it,
    /// the clock moves past the plan lifetime, then a reader releases `first`. Returns `second`'s error (nil if it ran).
    func executeExpiringWhileQueued(_ engine: CleanupEngine, fifo: String, clock: Clock,
                                    first: CleanupPlan, second: CleanupPlan) async throws -> Error? {
        func wait(_ what: String, _ cond: () async -> Bool) async throws {
            for _ in 0..<1000 { if await cond() { return }; try await Task.sleep(nanoseconds: 5_000_000) }
            XCTFail("timed out waiting for \(what)")
        }
        let a = Task { try await engine.execute(first) }
        try await wait("first to hold the run slot") { await engine.runSlotState.held }
        let b = Task { () -> Error? in
            do { _ = try await engine.execute(second); return nil } catch { return error }
        }
        try await wait("second to queue") { await engine.runSlotState.queued == 1 }
        clock.advance(20 * 60)
        let reader = Thread {
            let fd = Darwin.open(fifo, O_RDONLY)
            var buf = [UInt8](repeating: 0, count: 65536)
            while read(fd, &buf, buf.count) > 0 {}
            Darwin.close(fd)
        }
        reader.start()
        _ = try await a.value
        let result = await b.value
        while !reader.isFinished { try await Task.sleep(nanoseconds: 10_000_000) }
        return result
    }
}
