import Foundation
import XCTest
@testable import DiskKeeperCore

final class CleanupExecuteTests: CleanupTestCase {
    func testExecuteMovesToTrashAndWritesAudit() async throws {
        for n in ["a", "b", "c"] { try fx.file("home/cache/\(n)/f", bytes: 3000) }
        let items = try ["a", "b", "c"].map { try item("home/cache/\($0)", rule: "rule.\($0)") }
        let engine = try makeEngine()
        let plan = await engine.plan(items)
        let report = try await engine.execute(plan)
        XCTAssertEqual(report.results.count, 3)
        for n in ["a", "b", "c"] { XCTAssertFalse(exists("home/cache/\(n)")) }
        XCTAssertEqual(trashContents().count, 3)
        XCTAssertGreaterThan(report.freedBytes, 0)
        let records = try AuditLog.read(auditURL)
        XCTAssertEqual(records.count, 3)
        for (r, it) in zip(records, items) {
            XCTAssertEqual(r.result, "trashed"); XCTAssertEqual(r.runID, plan.id)
            XCTAssertEqual(r.ruleID, it.ruleID); XCTAssertEqual(r.bytes, it.sizeAllocated)
            XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(r.trashPath)))
        }
        let lines = try String(contentsOf: auditURL).split(separator: "\n")
        XCTAssertEqual(lines.count, 3)
        for l in lines { XCTAssertNoThrow(try DiskKeeperJSON.makeDecoder().decode(AuditRecord.self, from: Data(l.utf8))) }
    }

    private func tampered(_ plan: CleanupPlan, _ edit: (inout [String: Any]) -> Void) throws -> CleanupPlan {
        let data = try DiskKeeperJSON.makeEncoder().encode(plan)
        var obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        var entries = obj["entries"] as! [[String: Any]]
        var e = entries[0]
        var item = e["item"] as! [String: Any]
        edit(&item)
        e["item"] = item; e["blockers"] = []
        entries[0] = e; obj["entries"] = entries
        return try DiskKeeperJSON.makeDecoder().decode(CleanupPlan.self, from: JSONSerialization.data(withJSONObject: obj))
    }

    func testKeepAndProtectedRefusedAtExecuteEvenIfPlanTampered() async throws {
        try fx.file("home/cache/a/f", bytes: 100); try fx.file("home/.ssh/x", bytes: 100)
        let engine = try makeEngine()
        let plan = await engine.plan([try item("home/cache/a")])
        let keep = try tampered(plan) { $0["tier"] = "keep" }
        var report = try await engine.execute(keep)
        XCTAssertEqual(skippedCodes(report.results[0].outcome), ["keepTier"])
        XCTAssertTrue(exists("home/cache/a/f"))

        let plan2 = await engine.plan([try item("home/cache/a")])
        let prot = try tampered(plan2) { $0["path"] = self.fx.path("home/.ssh/x") }
        report = try await engine.execute(prot)
        XCTAssertTrue(skippedCodes(report.results[0].outcome).contains("protectedPath"))
        XCTAssertTrue(exists("home/.ssh/x")); XCTAssertTrue(trashContents().isEmpty)
    }

    func testModifiedAfterScanSkippedChangedSinceScan() async throws {
        try fx.file("home/cache/a/f", bytes: 100)
        let engine = try makeEngine()
        let plan = await engine.plan([try item("home/cache/a")])
        XCTAssertTrue(plan.entries[0].isExecutable)
        let h = try FileHandle(forWritingTo: URL(fileURLWithPath: fx.path("home/cache/a/f")))
        try h.seekToEnd(); try h.write(contentsOf: Data(repeating: 1, count: 2 << 20)); try h.close()
        try fx.setMTime("home/cache/a/f", Date().addingTimeInterval(10))
        let report = try await engine.execute(plan)
        XCTAssertEqual(skippedCodes(report.results[0].outcome), ["changedSinceScan"])
        XCTAssertTrue(exists("home/cache/a/f"))
        XCTAssertEqual(try AuditLog.read(auditURL)[0].reasons, ["changedSinceScan"])
    }

    func testSmallChangeWithinToleranceStillTrashed() async throws {
        try fx.file("home/cache/a/f", bytes: 100)
        let engine = try makeEngine()
        let it = try item("home/cache/a")
        let plan = await engine.plan([it])
        let h = try FileHandle(forWritingTo: URL(fileURLWithPath: fx.path("home/cache/a/f")))
        try h.seekToEnd(); try h.write(contentsOf: Data([1])); try h.close()
        try fx.setMTime("home/cache/a/f", it.lastModified!)
        let report = try await engine.execute(plan)
        guard case .trashed = report.results[0].outcome else { return XCTFail("\(report.results[0].outcome)") }
    }

    func testPartialFailureDoesNotAbortBatch() async throws {
        for n in ["a", "b", "c"] { try fx.file("home/cache/\(n)", bytes: 10) }
        let engine = try makeEngine(trash: FailingTrash(inner: DirectoryTrash(root: trashDir), failOn: 2))
        let plan = await engine.plan(try ["a", "b", "c"].map { try item("home/cache/\($0)") })
        let report = try await engine.execute(plan)
        guard case .trashed = report.results[0].outcome, case .failed = report.results[1].outcome,
              case .trashed = report.results[2].outcome else { return XCTFail("\(report.results)") }
        XCTAssertEqual(try AuditLog.read(auditURL).map(\.result), ["trashed", "failed", "trashed"])
        XCTAssertTrue(exists("home/cache/b"))
    }

    func testPlanSingleUseAndExpiry() async throws {
        try fx.file("home/cache/a", bytes: 10)
        let clock = Clock()
        let engine = try makeEngine(now: { clock.now() })
        let plan = await engine.plan([try item("home/cache/a")])
        _ = try await engine.execute(plan)
        do { _ = try await engine.execute(plan); XCTFail() } catch { XCTAssertEqual(error as? CleanupError, .planAlreadyExecuted) }
        let stranger = CleanupPlan(createdAt: Date(), entries: [])
        do { _ = try await engine.execute(stranger); XCTFail() } catch { XCTAssertEqual(error as? CleanupError, .unknownPlan) }
        try fx.file("home/cache/b", bytes: 10)
        let plan2 = await engine.plan([try item("home/cache/b")])
        clock.advance(16 * 60)
        do { _ = try await engine.execute(plan2); XCTFail() } catch { XCTAssertEqual(error as? CleanupError, .planExpired) }
        XCTAssertTrue(exists("home/cache/b"))
    }

    func testAuditUnavailableAbortsBeforeAnyAction() async throws {
        try fx.file("home/cache/a", bytes: 10)
        try fx.dir("real"); try fx.symlink("audit", to: fx.path("real"))
        let engine = try makeEngine()
        let plan = await engine.plan([try item("home/cache/a")])
        do { _ = try await engine.execute(plan); XCTFail() } catch {
            guard case CleanupError.auditLogUnavailable = error else { return XCTFail("\(error)") }
        }
        XCTAssertTrue(exists("home/cache/a")); XCTAssertTrue(trashContents().isEmpty)
    }

    func testAuditWriteFailureStopsRemaining() async throws {
        for n in ["a", "b", "c"] { try fx.file("home/cache/\(n)", bytes: 10) }
        let audit = AuditLog(fileURL: auditURL)
        await audit._failAfter(1)
        let engine = try makeEngine(audit: audit)
        let plan = await engine.plan(try ["a", "b", "c"].map { try item("home/cache/\($0)") })
        let report = try await engine.execute(plan)
        XCTAssertNotNil(report.auditFailure)
        guard case .trashed = report.results[0].outcome else { return XCTFail() }
        // Item 2 was acted on before its audit line failed; item 3 must not be touched.
        XCTAssertEqual(report.results[2].outcome, .notAttempted)
        XCTAssertTrue(exists("home/cache/c"))
    }

    func testCancellationBetweenItems() async throws {
        for n in ["a", "b", "c"] { try fx.file("home/cache/\(n)", bytes: 10) }
        let engine = try makeEngine()
        let plan = await engine.plan(try ["a", "b", "c"].map { try item("home/cache/\($0)") })
        final class Box: @unchecked Sendable { var task: Task<CleanupReport, Error>? }
        let box = Box()
        let started = Flag()
        box.task = Task {
            try await engine.execute(plan) { p in
                if p.done == 1 { started.set(); box.task?.cancel() }
            }
        }
        // The callback may fire before box.task is assigned; fall back to cancelling here.
        while !started.value { await Task.yield() }
        box.task?.cancel()
        let report = try await box.task!.value
        XCTAssertTrue(report.wasCancelled)
        XCTAssertEqual(report.results[1].outcome, .notAttempted)
        XCTAssertEqual(report.results[2].outcome, .notAttempted)
        XCTAssertEqual(try AuditLog.read(auditURL).count, 1)
    }

    func testPermanentDeleteWhenEnabled() async throws {
        try fx.file("home/cache/a", bytes: 10)
        let remover = RecordingRemover()
        var o = CleanupOptions(); o.requestPermanentDelete = true; o.permanentDeleteEnabled = true
        let engine = try makeEngine(remover: remover, options: o)
        let plan = await engine.plan([try item("home/cache/a")])
        let report = try await engine.execute(plan)
        XCTAssertEqual(report.results[0].outcome, .deleted)
        XCTAssertEqual(remover.removed, [fx.path("home/cache/a")])
        XCTAssertEqual(try AuditLog.read(auditURL)[0].result, "deleted")
    }
}
