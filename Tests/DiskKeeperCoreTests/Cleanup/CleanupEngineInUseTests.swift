import Foundation
import XCTest
@testable import DiskKeeperCore

/// The engine with an injected process source: no real process is read.
final class CleanupEngineInUseTests: CleanupTestCase {
    private let source = FakeUsageSource([])
    private let old = Date(timeIntervalSince1970: 1_577_836_800)   // 2020-01-01

    private func engine(_ source: (any ProcessUsageSource)?) throws -> CleanupEngine {
        CleanupEngine(pathGuard: try makeGuard(), auditLog: AuditLog(fileURL: auditURL),
                      trash: DirectoryTrash(root: trashDir), runningApps: FakeRunningApps(), inUse: source)
    }

    private func logs(modified: Date? = nil) throws -> ScanItem {
        _ = try fx.file("home/logs/a.log", bytes: 100)
        let d = modified ?? old
        try setMTime(fx.path("home/logs/a.log"), d)
        try setMTime(fx.path("home/logs"), d)
        return try item("home/logs")
    }

    func testFreeItemIsTrashed() async throws {
        let item = try logs()
        let e = try engine(source)
        let report = try await e.execute(await e.plan([item]))
        if case .trashed? = report.results.first?.outcome {} else { XCTFail("\(report.results)") }
        XCTAssertEqual(trashContents().count, 1)
    }

    func testOpenedAfterPlanIsSkippedAndNothingTrashed() async throws {
        let item = try logs()
        let e = try engine(source)
        let plan = await e.plan([item])
        XCTAssertTrue(plan.entries[0].isExecutable)
        source.set([ProcessHold(pid: 77, name: "tail", uid: getuid(), openPaths: [fx.path("home/logs/a.log")])])
        let report = try await e.execute(plan)
        guard case .skipped(let b)? = report.results.first?.outcome else { return XCTFail("\(report.results)") }
        XCTAssertEqual(b, [.inUse(process: "tail", pid: 77)])
        XCTAssertTrue(exists("home/logs/a.log"))
        XCTAssertTrue(trashContents().isEmpty, "the trash adapter was never reached")
    }

    func testHeldAtPlanTimeBlocksThePlanEntry() async throws {
        let item = try logs()
        source.set([ProcessHold(pid: 5, name: "node", uid: getuid(), cwd: fx.path("home/logs"))])
        let plan = await (try engine(source)).plan([item])
        XCTAssertEqual(plan.entries[0].blockers, [.inUse(process: "node", pid: 5)])
    }

    func testUnreadableSnapshotFailsClosedAtExecute() async throws {
        let item = try logs()
        let e = try engine(source)
        let plan = await e.plan([item])
        source.set(nil)
        let report = try await e.execute(plan)
        guard case .skipped(let b)? = report.results.first?.outcome else { return XCTFail("\(report.results)") }
        XCTAssertEqual(b, [.inUseUnknown])
        XCTAssertTrue(exists("home/logs/a.log"))
        XCTAssertTrue(trashContents().isEmpty)
    }

    func testRecentlyModifiedBlocks() async throws {
        let item = try logs(modified: Date().addingTimeInterval(-600))
        let plan = await (try engine(source)).plan([item])
        XCTAssertTrue(plan.entries[0].blockers.contains(.modifiedRecently), "\(plan.entries[0].blockers)")
    }

    func testOldItemIsNotRecent() async throws {
        let item = try logs(modified: Date().addingTimeInterval(-2 * 3600))
        let plan = await (try engine(source)).plan([item])
        XCTAssertFalse(plan.entries[0].blockers.contains(.modifiedRecently))
    }

    func testOneSnapshotPerExecuteAndItIsNotReusedAcrossRuns() async throws {
        _ = try fx.file("home/a/x", bytes: 10); _ = try fx.file("home/b/x", bytes: 10)
        for d in ["home/a/x", "home/a", "home/b/x", "home/b"] { try setMTime(fx.path(d), old) }
        let e = try engine(source)
        let plan = await e.plan([try item("home/a"), try item("home/b")])
        let afterPlan = source.callCount
        _ = try await e.execute(plan)
        XCTAssertEqual(source.callCount - afterPlan, 1, "one fresh snapshot for the whole run")
        XCTAssertGreaterThanOrEqual(afterPlan, 1, "plan takes its own")
    }

    func testBlockerCodesAreStable() {
        XCTAssertEqual(CleanupBlocker.inUse(process: "x", pid: 1).code, "inUse")
        XCTAssertEqual(CleanupBlocker.inUseUnknown.code, "inUseUnknown")
        XCTAssertEqual(CleanupBlocker.modifiedRecently.code, "modifiedRecently")
    }
}
