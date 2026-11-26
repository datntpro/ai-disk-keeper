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
}
