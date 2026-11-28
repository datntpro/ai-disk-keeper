import AppKit
import DiskKeeperCore
import SwiftUI
import XCTest
@testable import AIDiskKeeperUI

@MainActor
final class RulesPolicyFailClosedTests: XCTestCase {
    private var dir: URL!
    private var env: PathEnvironment!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("adk-t23f-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        env = PathEnvironment(home: dir.path + "/home", temporaryDirectory: dir.path + "/tmp")
        addTeardownBlock { [dir] in
            _ = chmod(dir!.path, 0o700)
            try? FileManager.default.removeItem(at: dir!)
        }
    }

    private func item() -> ScanItem {
        ScanItem(url: URL(fileURLWithPath: env.home + "/x"), displayName: "x", tool: "t", category: .aiToolData,
                 sizeAllocated: 1, sizeLogical: 1, fileCount: 1, lastModified: nil, tier: .safe,
                 explanation: "x", ruleID: "t.r")
    }

    /// F1 case 1: the save fails (full disk). The Keep still holds in memory and the engine provider sees it.
    func testFailedSaveStillEnforcesTheChange() throws {
        // A directory where settings.json should be makes every save fail.
        let file = dir.appendingPathComponent("settings.json")
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        let m = SettingsModel(store: SettingsStore(fileURL: file), environment: env, probe: { .unknown })
        let it = item()
        m.overrideTier(of: it, to: .keep)
        XCTAssertTrue(m.userPolicySaveFailed)
        XCTAssertEqual(m.userPolicyProvider.policy.effectiveTier(for: it), .keep)
        XCTAssertTrue(m.userPolicyProvider.isTrusted)
        m.ignoreItem(it.id)
        XCTAssertTrue(m.userPolicyProvider.policy.hides(it))
    }

    /// F1 case 2: settings.json exists but can't be decoded (newer schema). Cleanup is blocked until acknowledged.
    func testUnreadableSettingsAtLaunchIsUntrustedUntilAcknowledged() throws {
        let file = dir.appendingPathComponent("settings.json")
        try Data(#"{"schemaVersion":99,"tierOverrides":{"a":"keep"}}"#.utf8).write(to: file)
        let m = SettingsModel(store: SettingsStore(fileURL: file), environment: env, probe: { .unknown })
        XCTAssertTrue(m.userPolicyUnreadable)
        XCTAssertFalse(m.userPolicyProvider.isTrusted)
        m.acknowledgeUnreadablePolicy()
        XCTAssertTrue(m.userPolicyProvider.isTrusted)
        XCTAssertFalse(m.userPolicyUnreadable)
    }

    func testMissingSettingsFileIsTrusted() {
        let m = SettingsModel(store: SettingsStore(fileURL: dir.appendingPathComponent("none.json")), environment: env, probe: { .unknown })
        XCTAssertTrue(m.userPolicyProvider.isTrusted)
        XCTAssertFalse(m.userPolicyUnreadable)
    }

    func testBlockerHasCopyAndNextStep() {
        XCTAssertEqual(CleanupBlocker.userPolicyUnavailable.code, "userPolicyUnavailable")
        XCTAssertFalse(CleanupCopy.sentence(for: .userPolicyUnavailable).isEmpty)
    }

    /// F2: the Rules tab is backed by a scroll view, so the controls below the file list stay reachable.
    func testRulesTabHasAScrollView() {
        let m = SettingsModel(store: SettingsStore(fileURL: dir.appendingPathComponent("s.json")), environment: env, probe: { .unknown })
        let host = NSHostingView(rootView: RulesSettingsView(model: m).frame(width: 560, height: 420))
        host.frame = NSRect(x: 0, y: 0, width: 560, height: 420)
        host.layoutSubtreeIfNeeded()
        func hasScroll(_ v: NSView) -> Bool { v is NSScrollView || v.subviews.contains(where: hasScroll) }
        XCTAssertTrue(hasScroll(host), "the Rules form must scroll (.formStyle(.grouped))")
    }

    /// F5: hidden large files and duplicates drop out of the reports the modules and Care stages show.
    func testReportsDropHiddenEntries() {
        let f = LargeOldFix.file("Documents/hide.bin", mb: 10)
        let id = ScanItem.makeID(ruleID: "large.other", url: URL(fileURLWithPath: f.path))
        let report = LargeFileReport(files: [f, LargeOldFix.file("Documents/keep.bin", mb: 10)])
        XCTAssertEqual(UserPolicy(ignoredItemIDs: [id]).filtered(report).files.map(\.path), [LargeOldFix.root + "/Documents/keep.bin"])
        XCTAssertTrue(UserPolicy(disabledRuleIDs: ["large.other"]).filtered(report).files.isEmpty)
        XCTAssertEqual(UserPolicy.empty.filtered(report).files.count, 2)
    }
}
