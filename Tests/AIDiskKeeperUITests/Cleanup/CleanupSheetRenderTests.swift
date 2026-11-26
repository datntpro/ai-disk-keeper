import DiskKeeperCore
import SwiftUI
import XCTest
@testable import AIDiskKeeperUI

/// Smoke renders with `ImageRenderer`. With `ADK_SNAPSHOT_DIR` set the PNGs are written there (for the PR);
/// CI never sets it, so there is no golden comparison.
@MainActor
final class CleanupSheetRenderTests: XCTestCase {
    private func entry(_ name: String, tool: ToolID = .claudeCode, tier: RiskTier = .safe, size: Int64 = 50_000_000,
                       cleanup: CleanupMethod = .trash, blockers: [CleanupBlocker] = []) -> CleanupPlanEntry {
        CleanupPlanEntry(item: ItemFixtures.item(name, tool: tool, tier: tier, size: size, cleanup: cleanup),
                         action: .trash, blockers: blockers, fingerprint: nil)
    }

    private var plan: CleanupPlan {
        CleanupPlan(createdAt: Date(), entries: [
            entry("cache1"), entry("cache2"), entry("logs", size: 12_000_000),
            entry("wt", tool: "cursor", cleanup: .trashWorktree(mainRepoPath: "/tmp/fixture/repo")),
            entry("history", tier: .review),
            entry("Claude cache", blockers: [.appRunning(bundleID: "com.anthropic.claudefordesktop")]),
            entry("system", tier: .keep, blockers: [.keepTier]),
        ])
    }

    private var report: CleanupReport {
        func r(_ n: String, _ o: CleanupOutcome) -> CleanupItemResult {
            CleanupItemResult(itemID: n, path: "/tmp/fixture/\(n)", bytes: 50_000_000, action: .trash, outcome: o, finishedAt: Date())
        }
        let detail = ChangeDetail(scannedBytes: 1, currentBytes: 2, scannedModified: nil, currentModified: nil)
        return CleanupReport(planID: UUID(), startedAt: Date(), finishedAt: Date(), results: [
            r("cache2", .trashed(trashPath: nil)),
            r("cache1", .skipped([.changedSinceScan(detail)])),
            r("broken", .failed("Operation not permitted")),
            r("Some.app", .skipped([.needsAppManagementPermission(bundleID: "com.example.app")])),
        ], wasCancelled: false, auditFailure: nil)
    }

    private func render(_ name: String, _ view: some View) {
        for scheme in [ColorScheme.light, .dark] {
            let r = ImageRenderer(content: view.frame(width: 680, height: 560).background(.adkBg)
                .environment(\.colorScheme, scheme))
            r.scale = 2
            guard let img = r.cgImage else { XCTFail("\(name) \(scheme) did not render"); continue }
            XCTAssertGreaterThan(img.width, 0)
            if let dir = ProcessInfo.processInfo.environment["ADK_SNAPSHOT_DIR"] {
                let rep = NSBitmapImageRep(cgImage: img)
                try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                try? rep.representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name)-\(scheme == .dark ? "dark" : "light").png"))
            }
        }
    }

    func testReviewSheetRenders() {
        var sheet = CleanupReviewSheet(plan: plan, notice: nil, onRecheck: {}, onCancel: {}, onConfirm: {})
        sheet.scrolls = false
        render("cleanup-review", sheet)
    }

    private let env = PathEnvironment(home: "/tmp/fixture", temporaryDirectory: "/tmp")

    func testResultsRender() {
        var v = CleanupResultView(report: report, environment: env, freeBefore: 40_000_000_000, onRescan: {}, onDone: { _ in })
        v.scrolls = false
        render("cleanup-results", v)
    }

    func testResultsRenderWithoutFreeSpace() {
        var v = CleanupResultView(report: report, environment: env, onDone: { _ in })
        v.scrolls = false
        render("cleanup-results-nofree", v)
    }
}
