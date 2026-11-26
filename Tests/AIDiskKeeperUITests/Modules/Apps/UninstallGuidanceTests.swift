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

    func testQuitStatesResolveAndRead() {
        let name = app.name
        let run = UninstallGuidance.RunInfo(quit: .stuck, canQuit: true)
        XCTAssertEqual(UninstallGuidance.resolve(app: app, availability: .running, last: nil, run: run),
                       .running(name: name, quit: .stuck, background: [], otherUser: false, canQuit: true))
        XCTAssertEqual(UninstallGuidance.resolve(app: app, availability: .running, last: nil, run: .init(unknown: true)), .runningUnknown(name: name))
        XCTAssertEqual(UninstallGuidance.resolve(app: app, availability: .running, last: nil, run: .init(selfApp: true)), .selfApp)
        XCTAssertEqual(UninstallGuidance.resolve(app: app, availability: .available, last: nil, quit: .done), .quitDone(name: name))
        XCTAssertEqual(UninstallGuidance.resolve(app: app, availability: .viewOnly(.apple), last: nil, run: .init(selfApp: true)), .locked(.apple))
        let states: [QuitFlowState?] = [nil, .quitting, .stuck, .forcing, .settling, .failed, .relaunched, .backgroundRemains, .auditFailed,
                                        .refused(.selfApp), .refused(.otherUser), .refused(.appleOrSystem)]
        for q in states {
            let g = UninstallGuidance.running(name: name, quit: q, background: ["x (1)"], otherUser: true, canQuit: false)
            XCTAssertFalse(UninstallGuidanceCard.text(g).isEmpty, "\(String(describing: q))")
        }
        XCTAssertTrue(UninstallGuidanceCard.text(.running(name: name, quit: .stuck)).contains("save"))
        XCTAssertTrue(UninstallGuidanceCard.text(.quitDone(name: name)).contains("uninstall it now"))
    }

    func testQuitCopyIsTranslatedAndPluralised() {
        L10n.withLanguage(.en) {
            XCTAssertEqual(UninstallerCopy.forceInstances(2), "2 copies are running.")
            XCTAssertEqual(UninstallerCopy.forceTitle("Notely"), "Force quit Notely?")
        }
        L10n.withLanguage(.vi) {
            XCTAssertEqual(UninstallerCopy.quitButton, "Thoát ứng dụng")
            XCTAssertEqual(UninstallerCopy.forceTitle("Notely"), "Buộc thoát Notely?")
            XCTAssertEqual(UninstallerCopy.forceInstances(2), "Đang có 2 bản chạy.")
            XCTAssertEqual(UninstallerCopy.background("A", "b (1)"), "Một tiến trình nền của A vẫn đang chạy: b (1). Hãy khởi động lại máy, hoặc kết thúc nó trong Activity Monitor.")
        }
    }
}
