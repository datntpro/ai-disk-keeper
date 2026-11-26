import DiskKeeperCore
import XCTest
@testable import AIDiskKeeperUI

@MainActor
final class CleanupFlowModelTests: XCTestCase {
    private let items = [makeItem("a"), makeItem("b", tier: .review)]

    private func make() -> (CleanupFlowModel, FakeCleanupEngine) {
        let e = FakeCleanupEngine()
        return (CleanupFlowModel(engine: e), e)
    }

    private func previewPlan(_ m: CleanupFlowModel) -> CleanupPlan? {
        if case .previewing(let p, _) = m.state { return p } else { return nil }
    }

    private func waitUntil(_ cond: @MainActor () -> Bool) async {
        for _ in 0..<400 where !cond() { try? await Task.sleep(nanoseconds: 5_000_000) }
    }

    func testConfirmWithoutPreviewNeverExecutes() async {
        let (m, e) = make()
        await m.confirm() // idle
        await m.review(items)
        await m.confirm()
        await m.confirm() // finished
        let planned = await e.executedPlans.count
        XCTAssertEqual(planned, 1) // only the legitimate confirm
        m.dismiss()
        await m.confirm() // idle again
        let n = await e.executedPlans.count
        XCTAssertEqual(n, 1)
    }

    func testConfirmInFailedStateIsNoOp() async {
        let (m, e) = make()
        await m.review(items)
        await e.throwOnce(.auditLogUnavailable("x"))
        await m.confirm()
        await m.confirm()
        let n = await e.executedPlans.count
        XCTAssertEqual(n, 1)
    }

    func testPlanPassedBackUnchanged() async {
        let (m, e) = make()
        await m.review(items)
        let shown = previewPlan(m)
        await m.confirm()
        let executed = await e.executedPlans
        let issued = await e.issuedPlans
        XCTAssertEqual(executed.count, 1)
        XCTAssertEqual(executed[0], issued[0])
        XCTAssertEqual(executed[0], shown)
        XCTAssertEqual(executed[0].id, issued[0].id)
        guard case .finished = m.state else { return XCTFail("\(m.state)") }
    }

    func testDoubleConfirmExecutesOnce() async {
        let (m, e) = make()
        await e.setHold(true)
        await m.review(items)
        let first = Task { await m.confirm() }
        await waitUntil { m.isExecuting }
        await m.confirm() // second tap: state is .executing
        m.stop()
        await first.value
        let n = await e.executedPlans.count
        XCTAssertEqual(n, 1)
    }

    func testPlanExpiredReplansWithNoticeAndNeverAutoExecutes() async {
        let (m, e) = make()
        await m.review(items)
        let old = previewPlan(m)
        await e.throwOnce(.planExpired)
        await m.confirm()
        guard case .previewing(let fresh, let notice) = m.state else { return XCTFail("\(m.state)") }
        XCTAssertEqual(notice, .refreshedBecauseExpired)
        XCTAssertNotEqual(fresh.id, old?.id)
        let n = await e.executedPlans.count
        XCTAssertEqual(n, 1)
        await m.confirm() // user confirms the refreshed preview
        let n2 = await e.executedPlans
        XCTAssertEqual(n2.count, 2)
        XCTAssertEqual(n2[1].id, fresh.id)
    }

    func testAuditLogUnavailableFails() async {
        let (m, e) = make()
        await m.review(items)
        await e.throwOnce(.auditLogUnavailable("disk full"))
        await m.confirm()
        guard case .failed(let msg) = m.state else { return XCTFail("\(m.state)") }
        XCTAssertTrue(msg.contains("disk full"))
        XCTAssertTrue(msg.contains("Nothing was changed"))
        await m.confirm()
        let n = await e.executedPlans.count
        XCTAssertEqual(n, 1)
    }

    func testStopMarksRemainingNotAttempted() async {
        let (m, e) = make()
        await e.setHold(true)
        await m.review(items)
        let run = Task { await m.confirm() }
        await waitUntil { m.isExecuting }
        m.stop()
        await run.value
        guard case .finished(let report, _) = m.state else { return XCTFail("\(m.state)") }
        XCTAssertTrue(report.wasCancelled)
        XCTAssertTrue(report.results.allSatisfy { $0.outcome == .notAttempted })
    }

    func testProgressAppliedOnMainActor() async {
        let (m, e) = make()
        await e.setHold(true)
        await e.setProgress([CleanupProgress(done: 1, total: 2, currentPath: "/tmp/fake/a")])
        await m.review(items)
        let run = Task { await m.confirm() }
        await waitUntil {
            if case .executing(_, let p) = m.state { return p?.done == 1 } else { return false }
        }
        guard case .executing(_, let p) = m.state else { return XCTFail("\(m.state)") }
        XCTAssertEqual(p?.currentPath, "/tmp/fake/a")
        m.stop()
        await run.value
    }

    func testZeroExecutableEntriesConfirmIsNoOp() async {
        let (m, e) = make()
        await e.setBlockers(Dictionary(uniqueKeysWithValues: items.map { ($0.id, [CleanupBlocker.missing]) }))
        await m.review(items)
        await m.confirm()
        let n = await e.executedPlans.count
        XCTAssertEqual(n, 0)
        guard case .previewing = m.state else { return XCTFail("\(m.state)") }
    }

    func testRecheckIssuesNewPlanAndOldNeverExecuted() async {
        let (m, e) = make()
        await m.review(items)
        let old = previewPlan(m)
        await m.recheck()
        let fresh = previewPlan(m)
        XCTAssertNotEqual(old?.id, fresh?.id)
        await m.confirm()
        let executed = await e.executedPlans
        XCTAssertEqual(executed.map(\.id), [fresh?.id])
        let issued = await e.issuedPlans
        XCTAssertEqual(issued.count, 2)
    }

    func testDismissNotAllowedWhileExecuting() async {
        let (m, e) = make()
        await e.setHold(true)
        await m.review(items)
        let run = Task { await m.confirm() }
        await waitUntil { m.isExecuting }
        m.dismiss()
        XCTAssertTrue(m.isExecuting)
        m.stop()
        await run.value
        m.dismiss()
        guard case .idle = m.state else { return XCTFail("\(m.state)") }
    }

    func testDismissDuringPlanningDoesNotReopenPreview() async {
        let (m, e) = make()
        await e.holdPlan(true)
        let run = Task { await m.review(items) }
        await waitUntil { if case .planning = m.state { return true } else { return false } }
        m.dismiss()
        guard case .idle = m.state else { return XCTFail("\(m.state)") }
        await e.holdPlan(false)
        await run.value
        guard case .idle = m.state else { return XCTFail("resurrected: \(m.state)") }
        XCTAssertFalse(m.isActive)
        await m.confirm()
        let n = await e.executedPlans.count
        XCTAssertEqual(n, 0)
    }

    func testDismissDuringRecheckDoesNotReopenPreview() async {
        let (m, e) = make()
        await m.review(items)
        await e.holdPlan(true)
        let run = Task { await m.recheck() }
        await waitUntil { if case .planning = m.state { return true } else { return false } }
        m.dismiss()
        await e.holdPlan(false)
        await run.value
        guard case .idle = m.state else { return XCTFail("resurrected: \(m.state)") }
    }

    func testNewReviewAfterDismissedPlanWorks() async {
        let (m, e) = make()
        await e.holdPlan(true)
        let first = Task { await m.review(items) }
        await waitUntil { if case .planning = m.state { return true } else { return false } }
        m.dismiss()
        await e.holdPlan(false)
        await first.value
        await m.review(items)
        guard case .previewing = m.state else { return XCTFail("\(m.state)") }
    }
}
