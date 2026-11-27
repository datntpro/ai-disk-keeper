import Darwin
import XCTest
@testable import DiskKeeperCore

final class ProcessTableTests: XCTestCase {
    private func rec(_ pid: pid_t, _ ppid: pid_t) -> ProcessRecord { ProcessRecord(pid: pid, ppid: ppid, name: "p\(pid)") }
    private func snap(_ records: [ProcessRecord]) -> ProcessTableSnapshot {
        ProcessTableSnapshot(at: .now, wall: Date(), records: records)
    }

    /// The only live check: our own test process.
    func testReadsOwnProcess() throws {
        let table = LibprocProcessTable()
        let before = try XCTUnwrap(table.snapshot()?.records.first { $0.pid == getpid() })
        XCTAssertEqual(before.uid, getuid())
        XCTAssertEqual(before.ppid, getppid())
        let cwd = FileManager.default.currentDirectoryPath
        XCTAssertEqual(before.cwd.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path },
                       URL(fileURLWithPath: cwd).resolvingSymlinksInPath().path)
        XCTAssertNotEqual(before.startID, 0)
        let dir = try TemporaryDirectory()
        let url = dir.url.appendingPathComponent("w.bin")
        let fd = open(url.path, O_WRONLY | O_CREAT, 0o600)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        let chunk = [UInt8](repeating: 7, count: 8 << 20)
        _ = chunk.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        fsync(fd)
        let after = try XCTUnwrap(table.snapshot()?.records.first { $0.pid == getpid() })
        XCTAssertEqual(after.startID, before.startID)
        XCTAssertGreaterThanOrEqual(after.diskBytesWritten, before.diskBytesWritten)
    }

    func testOnlyOwnUserIsListed() throws {
        let records = try XCTUnwrap(LibprocProcessTable().snapshot()).records
        XCTAssertFalse(records.isEmpty)
        XCTAssertTrue(records.allSatisfy { $0.uid == getuid() })
    }

    func testDescendantsAndAncestors() {
        let s = snap([rec(1, 0), rec(2, 1), rec(3, 2), rec(4, 2), rec(5, 3), rec(9, 1)])
        XCTAssertEqual(Set(s.descendants(of: 2).map(\.pid)), [3, 4, 5])
        XCTAssertEqual(s.children(of: 2).map(\.pid).sorted(), [3, 4])
        XCTAssertEqual(s.ancestors(of: 5).map(\.pid), [3, 2, 1])
        XCTAssertTrue(s.descendants(of: 5).isEmpty)
    }

    func testPPIDCycleTerminates() {
        let s = snap([rec(1, 2), rec(2, 3), rec(3, 1), rec(4, 4)])
        XCTAssertEqual(Set(s.descendants(of: 1).map(\.pid)), [2, 3])
        XCTAssertEqual(s.ancestors(of: 1).map(\.pid), [2, 3])
        XCTAssertTrue(s.descendants(of: 4).isEmpty)
        XCTAssertTrue(s.ancestors(of: 4).isEmpty)
    }
}
