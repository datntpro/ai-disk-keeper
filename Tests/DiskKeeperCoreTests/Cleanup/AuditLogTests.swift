import Darwin
import Foundation
import XCTest
@testable import DiskKeeperCore

final class AuditLogTests: CleanupTestCase {
    private func record(path: String = "/p", id: String = "i") -> AuditRecord {
        AuditRecord(timestamp: Date(), runID: UUID(), itemID: id, path: path, bytes: 1, action: .trash,
                    result: "trashed", trashPath: nil, ruleID: "r", tool: .claudeCode, reasons: [], error: nil)
    }

    func testFileCreatedWith0600AndDir0700() async throws {
        let log = AuditLog(fileURL: fx.url.appendingPathComponent("newdir/audit.jsonl"))
        try await log.open(); try await log.append(record()); await log.close()
        var st = stat()
        XCTAssertEqual(lstat(fx.path("newdir/audit.jsonl"), &st), 0)
        XCTAssertEqual(st.st_mode & 0o777, 0o600)
        XCTAssertEqual(lstat(fx.path("newdir"), &st), 0)
        XCTAssertEqual(st.st_mode & 0o777, 0o700)
    }

    func testRefusesSymlinkedFile() async throws {
        try fx.file("target", bytes: 0); try fx.dir("d")
        try fx.symlink("d/audit.jsonl", to: fx.path("target"))
        let log = AuditLog(fileURL: fx.url.appendingPathComponent("d/audit.jsonl"))
        do { try await log.open(); XCTFail() } catch {}
        try fx.symlink("linkdir", to: fx.path("d"))
        let log2 = AuditLog(fileURL: fx.url.appendingPathComponent("linkdir/x.jsonl"))
        do { try await log2.open(); XCTFail() } catch {}
    }

    func testNewlineInPathStaysOneLine() async throws {
        let log = AuditLog(fileURL: auditURL)
        try await log.open(); try await log.append(record(path: "/a\nb\r\nc")); await log.close()
        XCTAssertEqual(try String(contentsOf: auditURL).split(separator: "\n").count, 1)
        XCTAssertEqual(try AuditLog.read(auditURL)[0].path, "/a\nb\r\nc")
    }

    func testAppendIsAppendOnlyAcrossInstances() async throws {
        for n in 1...2 {
            let log = AuditLog(fileURL: auditURL)
            try await log.open(); try await log.append(record(id: "run\(n)")); await log.close()
        }
        XCTAssertEqual(try AuditLog.read(auditURL).map(\.itemID), ["run1", "run2"])
    }
}
