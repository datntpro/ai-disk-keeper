import Darwin
import Foundation
import XCTest
@testable import DiskKeeperCore

/// Real libproc, but only our own child: a shell that holds one file open and sits in another directory.
final class LibprocUsageSourceTests: XCTestCase {
    private var child: Process?

    override func tearDown() {
        child?.terminate()
        child?.waitUntilExit()
        child = nil
    }

    func testFindsOwnChildOpenFileAndCwd() throws {
        let dir = try TemporaryDirectory()
        let held = try dir.file("held/data.log", bytes: 4).path
        let cwd = try dir.dir("cwd").path
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "exec 3<\"$F\"; sleep 30"]
        p.environment = ["F": held, "PATH": "/usr/bin:/bin"]
        p.currentDirectoryURL = URL(fileURLWithPath: cwd)
        try p.run()
        child = p

        let source = LibprocUsageSource()
        var found: ProcessHold?
        for _ in 0..<50 {   // the shell needs a moment to open fd 3
            found = source.snapshot(userID: getuid())?.first { $0.pid == p.processIdentifier }
            if found?.openPaths.contains(where: { $0.hasSuffix("/held/data.log") }) == true { break }
            usleep(100_000)
        }
        let hold = try XCTUnwrap(found, "own child must be listed")
        let index = InUseIndex(source.snapshot(userID: getuid()) ?? [], currentUID: getuid())
        // The shell forks `sleep`, which inherits fd 3 and the cwd: either of the two is a correct holder.
        var ours: Set<pid_t> = [p.processIdentifier]
        ours.formUnion(LibprocProcessTable().snapshot()?.descendants(of: p.processIdentifier).map(\.pid) ?? [])
        func holder(_ path: String) -> pid_t { index.holder(of: path)?.pid ?? -1 }
        XCTAssertTrue(ours.contains(holder(dir.path("held"))), "open file: \(hold.openPaths)")
        XCTAssertTrue(ours.contains(holder(held)))
        XCTAssertTrue(ours.contains(holder(cwd)), "cwd counts")
        XCTAssertNil(index.holder(of: dir.path("elsewhere")))
        // After the child exits it holds nothing.
        p.terminate(); p.waitUntilExit()
        let after = InUseIndex(source.snapshot(userID: getuid()) ?? [], currentUID: getuid())
        XCTAssertNil(after.holder(of: dir.path("held")))
    }

    func testOwnProcessAndLaunchdAreSkipped() throws {
        let pids = Set((LibprocUsageSource().snapshot(userID: getuid()) ?? []).map(\.pid))
        XCTAssertFalse(pids.contains(getpid()))
        XCTAssertFalse(pids.contains(1))
    }

    func testOtherUidIsFilteredByTheTable() {
        struct Table: ProcessTableReading {
            func snapshot() -> ProcessTableSnapshot? {
                ProcessTableSnapshot(at: .now, wall: Date(), records: [
                    ProcessRecord(pid: 50, ppid: 1, uid: 0, name: "root-thing", cwd: "/x"),
                    ProcessRecord(pid: 51, ppid: 1, uid: 501, name: "mine", cwd: "/y"),
                    ProcessRecord(pid: 1, ppid: 0, uid: 501, name: "launchd", cwd: "/z"),
                ])
            }
        }
        struct NoFiles: OpenFileReading { func openPaths(of pid: pid_t) -> [String]? { nil } }
        let got = LibprocUsageSource(table: Table(), files: NoFiles(), selfPID: 999).snapshot(userID: 501)
        XCTAssertEqual(got?.map(\.name), ["mine"])
    }

    func testUnreadableTableIsNil() {
        struct Dead: ProcessTableReading { func snapshot() -> ProcessTableSnapshot? { nil } }
        XCTAssertNil(LibprocUsageSource(table: Dead()).snapshot(userID: 501))
    }
}
