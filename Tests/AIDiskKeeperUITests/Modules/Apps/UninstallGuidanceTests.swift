import DiskKeeperCore
import XCTest
@testable import AIDiskKeeperUI

@MainActor
final class UninstallGuidanceTests: XCTestCase {
    private let app = UninstallFix.slide

    private func report(_ blockers: [CleanupBlocker]) -> CleanupReport {
        let r = CleanupItemResult(itemID: "x", path: app.path, bytes: 1, action: .trash, outcome: .skipped(blockers), finishedAt: Date())
        return CleanupReport(planID: UUID(), startedAt: Date(), finishedAt: Date(), results: [r], wasCancelled: false, auditFailure: nil)
    }

    func testReportBlockersBecomeGuidance() {
        XCTAssertEqual(UninstallGuidance.from(report: report([.needsAppManagementPermission(bundleID: app.bundleID)]), bundleID: app.bundleID),
                       .appManagement(bundleID: app.bundleID))
        XCTAssertEqual(UninstallGuidance.from(report: report([.requiresAdmin(bundleID: app.bundleID)]), bundleID: app.bundleID),
                       .requiresAdmin(bundleID: app.bundleID))
        XCTAssertNil(UninstallGuidance.from(report: report([.needsAppManagementPermission(bundleID: "other")]), bundleID: app.bundleID))
        XCTAssertNil(UninstallGuidance.from(report: report([.appRunning(bundleID: app.bundleID)]), bundleID: app.bundleID))
    }

    func testResolveOrderAndCards() {
        let last = UninstallGuidance.appManagement(bundleID: app.bundleID)
        XCTAssertEqual(UninstallGuidance.resolve(app: app, availability: .available, last: last), last)
        XCTAssertNil(UninstallGuidance.resolve(app: UninstallFix.app("Notely"), availability: .available, last: last))
        XCTAssertEqual(UninstallGuidance.resolve(app: app, availability: .running, last: last), .running(name: "Slidecraft"))
        XCTAssertEqual(UninstallGuidance.resolve(app: app, availability: .viewOnly(.apple), last: nil), .locked(.apple))
        XCTAssertTrue(last.needsSettingsLink)
        XCTAssertTrue(UninstallGuidance.locked(.notOwnedByUser).needsReveal)
        XCTAssertFalse(UninstallGuidance.locked(.apple).needsReveal)
        for g in [last, .requiresAdmin(bundleID: "x"), .running(name: "A"), .locked(.symlink)] {
            XCTAssertFalse(UninstallGuidanceCard.text(g).isEmpty)
        }
        XCTAssertEqual(SystemSettingsLinks.appManagement.scheme, "x-apple.systempreferences")
    }
}
