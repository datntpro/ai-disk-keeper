import DiskKeeperCore
import XCTest
@testable import AIDiskKeeperUI

@MainActor
final class CleanupCoordinatorReportTests: XCTestCase {
    private func make() -> CleanupCoordinator {
        CleanupCoordinator(holder: CleanupEngineHolder(engine: FakeCleanupEngine()))
    }

    private func report() -> CleanupReport {
        CleanupReport(planID: UUID(), startedAt: Date(), finishedAt: Date(), results: [], wasCancelled: false, auditFailure: nil)
    }

    func testLastReportIsSetByFinishedWithReport() {
        let c = make()
        XCTAssertNil(c.lastReport)
        let r = report()
        c.finished(["a"], report: r)
        XCTAssertEqual(c.lastReport, r)
    }

    func testRequestRescanIncrements() {
        let c = make()
        c.requestRescan()
        c.requestRescan()
        XCTAssertEqual(c.rescanRequests, 2)
    }

    func testLegacyFinishedStillCallsTheCallback() async {
        let c = make()
        var got: Set<ScanItem.ID>?
        c.review([ItemFixtures.item("a")]) { got = $0 }
        c.finished(["a"])
        XCTAssertEqual(got, ["a"])
        XCTAssertNil(c.lastReport)
    }

    private func waitUntil(_ cond: @MainActor () -> Bool) async {
        for _ in 0..<600 where !cond() { try? await Task.sleep(nanoseconds: 5_000_000) }
    }

    /// Esc (or any dismissal other than Done) on the results screen must still report the run.
    func testDismissOnTheResultsScreenStillReports() async {
        let c = make()
        var got: Set<ScanItem.ID>?
        c.review([ItemFixtures.item("a"), ItemFixtures.item("b")]) { got = $0 }
        await waitUntil { c.flow.map { if case .previewing = $0.state { true } else { false } } ?? false }
        await c.flow?.confirm()
        guard case .finished(let report, _)? = c.flow?.state else { return XCTFail("not finished") }
        c.dismiss()
        XCTAssertEqual(got, Set(["a", "b"].compactMap { name in report.results.first { $0.path.hasSuffix("/\(name)") }?.itemID }))
        XCTAssertEqual(got?.count, 2)
        XCTAssertEqual(c.lastReport, report)
        XCTAssertFalse(c.isPresented)
    }

    func testDismissBeforeFinishDoesNotReport() async {
        let c = make()
        var called = false
        c.review([ItemFixtures.item("a")]) { _ in called = true }
        await waitUntil { c.flow.map { if case .previewing = $0.state { true } else { false } } ?? false }
        c.dismiss()
        XCTAssertFalse(called)
        XCTAssertNil(c.lastReport)
    }

    func testRescanGoesToTheOriginatingScreenWhenItGaveOne() {
        let c = make()
        var rescanned = 0
        c.review([ItemFixtures.item("a")], onRescan: { rescanned += 1 }) { _ in }
        c.requestRescan()
        XCTAssertEqual(rescanned, 1)
        XCTAssertEqual(c.rescanRequests, 0, "no normal scan when the screen re-checks itself")
    }
}
