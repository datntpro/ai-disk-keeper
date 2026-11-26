import XCTest
@testable import DiskKeeperCore

final class AuditLogQuitEventTests: XCTestCase {
    private func dir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("adk-quit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: d) }
        return d
    }

    private func record(_ mode: String = "force", _ phase: String = "requested") -> AppQuitAuditRecord {
        AppQuitAuditRecord(timestamp: Date(timeIntervalSince1970: 1_700_000_000), flowID: UUID(), bundleID: "com.t.a", appPath: "/h/Applications/A.app",
                           mode: mode, phase: phase, result: phase == "result" ? "quit" : nil, pids: [10, 11], instanceCount: 2)
    }

    func testAppendsLinesThatRoundTrip() async throws {
        let url = try dir().appendingPathComponent("audit.jsonl")
        let log = AuditLog(fileURL: url)
        let r = record()
        try await log.appendQuitEvent(r)
        try await log.appendQuitEvent(record("force", "result"))
        let lines = try String(contentsOf: url).split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        let back = try DiskKeeperJSON.makeDecoder().decode(AppQuitAuditRecord.self, from: Data(lines[0].utf8))
        XCTAssertEqual(back, r)
        XCTAssertEqual(back.kind, "appQuit")
        XCTAssertTrue(lines[0].contains("\"kind\":\"appQuit\""))
    }

    func testReadStillReturnsOnlyCleanupRecords() async throws {
        let url = try dir().appendingPathComponent("audit.jsonl")
        let log = AuditLog(fileURL: url)
        let cleanup = AuditRecord(timestamp: Date(timeIntervalSince1970: 1_700_000_000), runID: UUID(), itemID: "i", path: "/x", bytes: 1,
                                  action: .trash, result: "trashed", trashPath: nil, ruleID: "r", tool: .apps, reasons: [], error: nil)
        try await log.open()
        try await log.append(cleanup)
        await log.close()
        try await log.appendQuitEvent(record())
        try await log.open()
        try await log.append(cleanup)
        await log.close()
        let read = try AuditLog.read(url)
        XCTAssertEqual(read.count, 2)
        XCTAssertEqual(try String(contentsOf: url).split(separator: "\n").count, 3)
    }

    func testAnUnsafeParentThrows() async throws {
        let d = try dir()
        let file = d.appendingPathComponent("not-a-dir")
        try Data().write(to: file)
        do {
            try await AuditLog(fileURL: file.appendingPathComponent("audit.jsonl")).appendQuitEvent(record())
            XCTFail("expected a throw")
        } catch {}
    }
}
