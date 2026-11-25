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

    private func expectThrow(_ engine: CleanupEngine, _ plan: CleanupPlan, _ expected: CleanupError,
                             file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await engine.execute(plan); XCTFail("did not throw", file: file, line: line) }
        catch { XCTAssertEqual(error as? CleanupError, expected, file: file, line: line) }
    }

    /// Spec change (coordinator decision): a modified plan is refused outright, before anything is touched.
    func testTamperedPlanIsRefusedBeforeAnyAction() async throws {
        try fx.file("home/cache/a/f", bytes: 100); try fx.file("home/.ssh/x", bytes: 100)
        let engine = try makeEngine()
        let plan = await engine.plan([try item("home/cache/a")])
        let e = plan.entries[0]

        var keepItem = e.item; keepItem.tier = .keep
        let keep = CleanupPlan(id: plan.id, createdAt: plan.createdAt, entries: [
            CleanupPlanEntry(item: keepItem, action: e.action, blockers: [], fingerprint: e.fingerprint)])
        await expectThrow(engine, keep, .planModified)

        let protectedItem = try item("home/.ssh/x")
        let prot = CleanupPlan(id: plan.id, createdAt: plan.createdAt, entries: [
            CleanupPlanEntry(item: protectedItem, action: e.action, blockers: [], fingerprint: e.fingerprint)])
        await expectThrow(engine, prot, .planModified)
        XCTAssertTrue(exists("home/cache/a/f")); XCTAssertTrue(exists("home/.ssh/x"))
        XCTAssertTrue(trashContents().isEmpty)

        // The genuine plan still runs (a refused plan is not consumed).
        let report = try await engine.execute(plan)
        guard case .trashed = report.results[0].outcome else { return XCTFail("\(report.results[0].outcome)") }
    }

    func testForgedEntryForUnplannedPathIsRefused() async throws {
        try fx.file("home/cache/a", bytes: 10); try fx.file("home/projects/app/src/main.c", bytes: 10)
        let engine = try makeEngine()
        let plan = await engine.plan([try item("home/cache/a")])
        let forged = CleanupPlan(id: plan.id, createdAt: plan.createdAt, entries: [
            CleanupPlanEntry(item: try item("home/projects/app/src"), action: .trash, blockers: [], fingerprint: nil)])
        await expectThrow(engine, forged, .planModified)
        XCTAssertTrue(exists("home/projects/app/src/main.c")); XCTAssertTrue(trashContents().isEmpty)
    }

    func testClearedPlanBlockersAreRefused() async throws {
        try fx.file("home/cache/a/b", bytes: 10)
        let engine = try makeEngine()
        let a = try item("home/cache/a"), b = try item("home/cache/a/b")
        let plan = await engine.plan([a, b])
        XCTAssertFalse(plan.entries[1].isExecutable)
        let cleared = CleanupPlan(id: plan.id, createdAt: plan.createdAt, entries: [
            plan.entries[0],
            CleanupPlanEntry(item: b, action: .trash, blockers: [], fingerprint: plan.entries[1].fingerprint)])
        await expectThrow(engine, cleared, .planModified)
        XCTAssertTrue(exists("home/cache/a/b"))
    }

    func testConcurrentExecutesAreSerializedAndEveryTrashIsAudited() async throws {
        let engine = try makeEngine()
        try fx.file("solo/f", bytes: 10)
        var many: [ScanItem] = []
        for i in 0..<40 { try fx.file("home/cache/m\(i)/f", bytes: 10); many.append(try item("home/cache/m\(i)")) }
        try fx.file("home/cache/solo/f", bytes: 10)
        let short = await engine.plan([try item("home/cache/solo")])
        let long = await engine.plan(many)
        async let r1 = engine.execute(long)
        async let r2 = engine.execute(short)
        let (a, b) = try await (r1, r2)
        let trashed = (a.results + b.results).filter { if case .trashed = $0.outcome { true } else { false } }
        XCTAssertEqual(trashed.count, 41)
        XCTAssertNil(a.auditFailure); XCTAssertNil(b.auditFailure)
        let records = try AuditLog.read(auditURL)
        XCTAssertEqual(records.filter { $0.result == "trashed" }.count, 41)
        XCTAssertEqual(trashContents().count, 41)
    }

    func testClockSetBackExpiresPlan() async throws {
        try fx.file("home/cache/a", bytes: 10)
        let clock = Clock()
        let engine = try makeEngine(now: { clock.now() })
        let plan = await engine.plan([try item("home/cache/a")])
        clock.advance(-7 * 86_400)
        await expectThrow(engine, plan, .planExpired)
        XCTAssertTrue(exists("home/cache/a"))
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
