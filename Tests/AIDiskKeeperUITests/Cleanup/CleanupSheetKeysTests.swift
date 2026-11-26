import SwiftUI
import XCTest
@testable import AIDiskKeeperUI

/// "Return does not confirm; ⌘⏎ does."
final class CleanupSheetKeysTests: XCTestCase {
    func testConfirmIsCommandReturn() {
        XCTAssertEqual(CleanupSheetKeys.confirm, KeyboardShortcut(.return, modifiers: .command))
        XCTAssertNotEqual(CleanupSheetKeys.confirm, KeyboardShortcut.defaultAction)
    }

    func testDefaultFocusIsCancelAndEscCancels() {
        XCTAssertEqual(CleanupSheetKeys.defaultFocus, .cancel)
        XCTAssertEqual(CleanupSheetKeys.cancel, KeyboardShortcut.cancelAction)
    }

    func testNoCleanupViewUsesDefaultAction() throws {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/AIDiskKeeperUI/Cleanup")
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty)
        for f in files {
            let text = try String(contentsOf: f, encoding: .utf8)
            XCTAssertFalse(text.contains(".defaultAction"), "\(f.lastPathComponent) must not use .defaultAction")
        }
    }
}
