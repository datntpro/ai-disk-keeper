import Darwin
import Foundation
import XCTest
@testable import DiskKeeperCore

/// Real-child tests for T20 (adopted from the PR #152 verifier). Real libproc + the real CleanupEngine; every process is a child this
/// test spawns and only those pids are signalled.
final class InUseRealChildTests: CleanupTestCase {
    private var children: [Process] = []

    override func tearDown() {
        for p in children where p.isRunning { p.terminate(); p.waitUntilExit() }
        children = []
        super.tearDown()
    }

    private let old = Date(timeIntervalSince1970: 1_577_836_800)

    private func ageTree(_ rel: String) throws {
        let root = fx.path(rel)
        let e = FileManager.default.enumerator(atPath: root)!
        for case let r as String in e { try setMTime(root + "/" + r, old) }
        try setMTime(root, old)
    }

    private func spawn(_ exe: String, _ args: [String], cwd: String? = nil, env: [String: String] = [:]) throws -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.environment = env.merging(["PATH": "/usr/bin:/bin"]) { a, _ in a }
        if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        try p.run()
        children.append(p)
        return p
    }

    /// Compiles a tiny C helper into `dir` (test-only; the product never runs a subprocess).
    private func compile(_ name: String, _ source: String, into dir: String) throws -> String {
        let c = fx.path("\(name).c"); let out = dir + "/" + name
        try source.write(toFile: c, atomically: true, encoding: .utf8)
        let cc = Process()
        cc.executableURL = URL(fileURLWithPath: "/usr/bin/cc")
        cc.arguments = ["-O0", "-o", out, c]
        try cc.run(); cc.waitUntilExit()
        XCTAssertEqual(cc.terminationStatus, 0, "cc failed")
        return out
    }

    private func engine() throws -> CleanupEngine {
        CleanupEngine(pathGuard: try makeGuard(), auditLog: AuditLog(fileURL: auditURL),
                      trash: DirectoryTrash(root: trashDir), runningApps: FakeRunningApps(), inUse: LibprocUsageSource())
    }

    private func waitHeld(_ path: String, timeout: Int = 50) -> ProcessHold? {
        for _ in 0..<timeout {
            if let h = InUseIndex(LibprocUsageSource().snapshot(userID: getuid()) ?? [], currentUID: getuid()).holder(of: path) { return h }
            usleep(100_000)
        }
        return nil
    }

    private func outcomeCodes(_ r: CleanupReport) -> [String] { r.results.flatMap { skippedCodes($0.outcome) } }

    // 1. Open fd, file opened AFTER plan, before execute: real engine must skip and never trash.
    func testOpenedAfterPlanRealEngine() async throws {
        _ = try fx.file("home/logs/a.log", bytes: 4096)
        try ageTree("home/logs")
        let e = try engine()
        let plan = await e.plan([try item("home/logs")])
        XCTAssertTrue(plan.entries[0].isExecutable, "\(plan.entries[0].blockers)")
        _ = try spawn("/bin/sh", ["-c", "exec 3<\"$F\"; exec /bin/sleep 30"], env: ["F": fx.path("home/logs/a.log")])
        XCTAssertNotNil(waitHeld(fx.path("home/logs")))
        let report = try await e.execute(plan)
        XCTAssertEqual(outcomeCodes(report), ["inUse"], "\(report.results)")
        XCTAssertTrue(exists("home/logs/a.log")); XCTAssertTrue(trashContents().isEmpty)
    }

    // 2. cwd inside the item (no open file).
    func testCwdInsideItemBlocks() async throws {
        _ = try fx.file("home/proj/sub/x", bytes: 10)
        try ageTree("home/proj")
        _ = try spawn("/bin/sleep", ["30"], cwd: fx.path("home/proj/sub"))
        XCTAssertNotNil(waitHeld(fx.path("home/proj")))
        let e = try engine()
        let report = try await e.execute(await e.plan([try item("home/proj")]))
        XCTAssertEqual(outcomeCodes(report), ["inUse"], "\(report.results)")
        XCTAssertTrue(trashContents().isEmpty)
    }

    // 3. mmapped file whose fd was closed: only a memory region references it.
    func testMmapAfterCloseIsDetected() async throws {
        _ = try fx.file("home/cache/blob.bin", bytes: 65536)
        try ageTree("home/cache")
        try fx.dir("bin")
        let helper = try compile("mmap_hold", """
        #include <fcntl.h>
        #include <sys/mman.h>
        #include <unistd.h>
        #include <stdio.h>
        int main(int c, char **v) { int fd = open(v[1], O_RDONLY); if (fd < 0) return 2;
          void *m = mmap(0, 65536, PROT_READ, MAP_SHARED, fd, 0); if (m == MAP_FAILED) return 3;
          close(fd); volatile char x = ((char*)m)[0]; (void)x; puts("ready"); fflush(stdout); sleep(30); return 0; }
        """, into: fx.path("bin"))
        let p = try spawn(helper, [fx.path("home/cache/blob.bin")], cwd: fx.path("bin"))
        usleep(500_000)
        XCTAssertTrue(p.isRunning)
        let e = try engine()
        let report = try await e.execute(await e.plan([try item("home/cache")]))
        XCTAssertEqual(outcomeCodes(report), ["inUse"], "mmapped-only file trashed while mapped: \(report.results)")
        XCTAssertTrue(trashContents().isEmpty, "TRASHED while mmapped")
    }

    // 4. A process whose executable lives inside the item (cwd elsewhere, no fd inside).
    func testRunningExecutableInsideItemIsDetected() async throws {
        try fx.dir("home/tools/bin")
        let helper = try compile("idle", "#include <unistd.h>\nint main(void){ sleep(30); return 0; }", into: fx.path("home/tools/bin"))
        try ageTree("home/tools")
        let p = try spawn(helper, [], cwd: fx.path("tmp"))
        usleep(300_000)
        XCTAssertTrue(p.isRunning)
        let e = try engine()
        let report = try await e.execute(await e.plan([try item("home/tools")]))
        XCTAssertEqual(outcomeCodes(report), ["inUse"], "running binary trashed: \(report.results)")
        XCTAssertTrue(trashContents().isEmpty, "TRASHED a running executable's directory")
    }

    // 5. Symlinked / case-variant item spelling still finds the holder.
    func testCaseVariantSpelling() throws {
        _ = try fx.file("home/Logs/A.log", bytes: 10)
        _ = try spawn("/bin/sh", ["-c", "exec 3<\"$F\"; exec /bin/sleep 30"], env: ["F": fx.path("home/Logs/A.log")])
        XCTAssertNotNil(waitHeld(fx.path("home/logs")), "case-folded spelling")
        XCTAssertNotNil(waitHeld(fx.path("home/Logs/a.LOG")))
        XCTAssertNil(InUseIndex(LibprocUsageSource().snapshot(userID: getuid()) ?? [], currentUID: getuid()).holder(of: fx.path("home/Log")))
    }

    // 6. Fail closed: a source that cannot read blocks every file item at execute, and nothing is trashed.
    func testUnreadableAtExecuteFailsClosed() async throws {
        struct Dead: ProcessUsageSource { func snapshot(userID: uid_t) -> [ProcessHold]? { nil } }
        _ = try fx.file("home/logs/a.log", bytes: 10); try ageTree("home/logs")
        let e = CleanupEngine(pathGuard: try makeGuard(), auditLog: AuditLog(fileURL: auditURL),
                              trash: DirectoryTrash(root: trashDir), runningApps: FakeRunningApps(), inUse: Dead())
        let report = try await e.execute(await e.plan([try item("home/logs")]))
        XCTAssertEqual(report.results.count, 1)
        XCTAssertTrue(outcomeCodes(report).contains("inUseUnknown"))
        XCTAssertTrue(trashContents().isEmpty)
    }

    // 7. Recent write inside an old dir after plan -> blocked at execute (modifiedRecently or changedSinceScan).
    func testTouchedAfterPlanBlocks() async throws {
        _ = try fx.file("home/logs/a.log", bytes: 10); try ageTree("home/logs")
        let e = try engine()
        let plan = await e.plan([try item("home/logs")])
        try setMTime(fx.path("home/logs/a.log"), Date())
        let codes = outcomeCodes(try await e.execute(plan))
        XCTAssertTrue(codes.contains("modifiedRecently"), "\(codes)")
        XCTAssertTrue(trashContents().isEmpty)
    }
}
