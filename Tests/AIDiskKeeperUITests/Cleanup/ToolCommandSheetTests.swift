import DiskKeeperCore
import SwiftUI
import XCTest
@testable import AIDiskKeeperUI

@MainActor
final class ToolCommandSheetTests: XCTestCase {
    private let id = "sha256:" + String(repeating: "a", count: 64)

    private func toolEntry(blockers: [CleanupBlocker] = []) -> CleanupPlanEntry {
        let path = VirtualItemPath.build(namespace: "adktest", target: "t1", kind: "image", id: id)!
        let item = ScanItem(url: URL(fileURLWithPath: path), displayName: "app:latest", tool: "docker", category: .aiToolData,
                            sizeAllocated: 2_000_000_000, sizeLogical: 2_000_000_000, fileCount: 1, lastModified: nil,
                            tier: .review, explanation: "x", ruleID: "docker.image",
                            cleanupMethod: .toolCommand(command: "docker", arguments: ["image", "rm", id]))
        let snap = ToolCommandSnapshot(specID: "docker.image.rm", executablePath: "/usr/local/bin/docker", argv: ["image", "rm", id],
                                       environmentDisplay: ["DOCKER_HOST": "unix:///x.sock", "HOME": "/h"], targetLabel: "t1")
        return CleanupPlanEntry(item: item, action: .trash, blockers: blockers, fingerprint: nil, toolCommand: blockers.isEmpty ? snap : nil)
    }

    private func trashEntry() -> CleanupPlanEntry {
        CleanupPlanEntry(item: ItemFixtures.item("cache"), action: .trash, blockers: [], fingerprint: nil)
    }

    func testRowShowsTheVerbatimCommandAndTheIrreversibleLabel() {
        let e = toolEntry()
        XCTAssertEqual(e.commandLine, "docker image rm \(id)")
        XCTAssertEqual(e.commandHelp, "DOCKER_HOST=unix:///x.sock /usr/local/bin/docker image rm \(id)")
        XCTAssertTrue(CleanupCopy.rowByTool("Docker").contains("can't be undone"))
    }

    func testBlockedRowFallsBackToTheDeclaredCommand() {
        XCTAssertEqual(toolEntry(blockers: [.toolCommandUnavailable]).commandLine, "docker image rm \(id)")
        XCTAssertNil(trashEntry().commandLine)
    }

    func testTitlesForMixedAndTrashOnlyPlans() {
        let mixed = CleanupPlan(createdAt: Date(), entries: [trashEntry(), toolEntry()])
        let trashOnly = CleanupPlan(createdAt: Date(), entries: [trashEntry()])
        XCTAssertTrue(mixed.hasExecutableToolCommands)
        XCTAssertFalse(trashOnly.hasExecutableToolCommands)
        XCTAssertTrue(CleanupCopy.titleClean(1_000_000).hasPrefix("Clean up"))
        XCTAssertTrue(CleanupCopy.confirmClean(1_000_000).hasPrefix("Clean up"))
        XCTAssertTrue(CleanupCopy.titleBytes(1_000_000).contains("Trash"))
        XCTAssertTrue(CleanupCopy.toolNotice(count: "2", tools: "Docker").contains("can't be undone"))
    }

    func testSheetsRender() {
        let plan = CleanupPlan(createdAt: Date(), entries: [trashEntry(), toolEntry(), toolEntry(blockers: [.toolNotRunning(tool: "docker", target: "t1")])])
        var sheet = CleanupReviewSheet(plan: plan, notice: nil, onRecheck: {}, onCancel: {}, onConfirm: {})
        sheet.scrolls = false
        let r = ImageRenderer(content: sheet.frame(width: 680).fixedSize(horizontal: false, vertical: true))
        XCTAssertNotNil(r.cgImage)
        let report = CleanupReport(planID: plan.id, startedAt: Date(), finishedAt: Date(), results: [
            CleanupItemResult(itemID: toolEntry().item.id, path: toolEntry().item.path, bytes: 2_000_000_000, action: .trash,
                              outcome: .ranCommand(exitStatus: 0), finishedAt: Date())], wasCancelled: false, auditFailure: nil)
        var result = CleanupResultView(report: report, environment: PathEnvironment(home: "/tmp/fixture", temporaryDirectory: "/tmp"),
                                       plan: plan, onDone: { _ in })
        result.scrolls = false
        XCTAssertNotNil(ImageRenderer(content: result.frame(width: 680).fixedSize(horizontal: false, vertical: true)).cgImage)
        XCTAssertEqual(CleanupCoordinator.trashedIDs(in: report), [toolEntry().item.id])
    }

    func testEveryNewBlockerHasASentence() {
        for b: CleanupBlocker in [.toolCommandUnavailable, .toolCommandNotAllowed(reason: "r"), .toolUnavailable(tool: "docker"),
                                  .toolNotRunning(tool: "docker", target: "t"), .inUseByTool(detail: "d")] {
            XCTAssertFalse(CleanupCopy.sentence(for: b).isEmpty, "\(b)")
        }
    }
}
