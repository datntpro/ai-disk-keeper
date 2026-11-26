import SwiftUI
import XCTest
@testable import AIDiskKeeperUI

@MainActor
final class StateCopyTests: XCTestCase {
    func testErrorCopyStatesWhatDidNotHappen() {
        for (lang, markers) in [(AppLanguage.en, ["Nothing was", "Couldn't", "not"]), (.vi, ["Không có gì", "không", "Không"])] {
            L10n.withLanguage(lang) {
                let texts = [StateCopy.errorScan, StateCopy.errorIndex, StateCopy.errorStartup, StateCopy.errorCleanupTitle, StateCopy.errorAuditBody]
                for t in texts { XCTAssertTrue(markers.contains { t.contains($0) }, "\(lang): \(t)") }
                for t in [StateCopy.errorScan, StateCopy.errorIndex, StateCopy.errorStartup] {
                    XCTAssertTrue(t.contains(lang == .en ? "Nothing was changed" : "Không có gì bị thay đổi"), t)
                }
            }
        }
    }

    func testAtMostOnePrimaryAction() {
        let two = [StateAction(title: "a") {}, StateAction(title: "b") {}]
        XCTAssertEqual(StateView(kind: .error, symbol: "x", title: "t", message: "m", actions: two).primaryActionCount, 1)
        XCTAssertEqual(StateView(kind: .empty, symbol: "x", title: "t", message: "m").primaryActionCount, 0)
        let destructive = [StateAction(title: "d", isDestructive: true) {}]
        XCTAssertEqual(StateView(kind: .error, symbol: "x", title: "t", message: "m", actions: destructive).primaryActionCount, 0)
    }

    func testEveryKindRendersInEveryMode() {
        let kinds: [StateView.Kind] = [.empty, .needsPermission, .error, .progress(nil), .firstRun, .filteredEmpty, .partialError, .blockingError]
        for kind in kinds {
            for (scheme, increased) in [(ColorScheme.light, false), (.dark, false), (.light, true)] {
                let view = StateView(kind: kind, symbol: "tray", title: "Title", message: "Message", actions: [StateAction(title: "Go") {}])
                    .frame(width: 360, height: 260)
                    .environment(\.colorScheme, scheme).environment(\.adkIncreasedContrast, increased)
                XCTAssertNotNil(ImageRenderer(content: view).cgImage, "\(kind) \(scheme)")
            }
        }
    }

    func testSettingsGearHasLabelInBothLanguages() {
        L10n.withLanguage(.en) { XCTAssertEqual(SettingsGearButton.title, "Settings") }
        L10n.withLanguage(.vi) { XCTAssertEqual(SettingsGearButton.title, "Cài đặt") }
    }
}
