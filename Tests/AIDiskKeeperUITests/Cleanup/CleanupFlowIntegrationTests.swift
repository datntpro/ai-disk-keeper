import DiskKeeperCore
import XCTest
@testable import AIDiskKeeperUI

/// select → dry-run preview → confirm → results against a REAL `CleanupEngine`, a temp home and a fake Trash
/// directory. Never touches the real home or the real Trash.
struct DirTrash: TrashAdapter {
    let root: URL
    func trashItem(at url: URL) throws -> URL? {
        let dest = root.appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)")
        try FileManager.default.moveItem(at: url, to: dest)
        return dest
    }
}

@MainActor
final class CleanupFlowIntegrationTests: XCTestCase {
    func testSelectPreviewConfirmMovesFixtureToFakeTrash() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("adk-ui-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let home = base.appendingPathComponent("home"), trashDir = base.appendingPathComponent("trash")
        let cache = home.appendingPathComponent("Library/Caches/Foo")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: trashDir, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 4096).write(to: cache.appendingPathComponent("blob"))
        let resolvedHome = URL(fileURLWithPath: home.path).resolvingSymlinksInPath().path
        let env = PathEnvironment(home: resolvedHome, temporaryDirectory: base.appendingPathComponent("tmp").path)
        let guardian = try ScanGuard(environment: env, protectPatterns: []).protectedPaths
        let audit = AuditLog.defaultURL(environment: env)
        let engine = CleanupEngine(pathGuard: guardian, auditLog: AuditLog(fileURL: audit),
                                   trash: DirTrash(root: trashDir), runningApps: WorkspaceRunningApps())

        let url = URL(fileURLWithPath: resolvedHome + "/Library/Caches/Foo")
        let r = try FileSizer().sizeBlocking(of: url)
        let item = ScanItem(url: url, displayName: "Foo cache", tool: .claudeCode, category: .systemJunk,
                            sizeAllocated: r.allocatedBytes, sizeLogical: r.logicalBytes, fileCount: r.fileCount,
                            lastModified: r.newestModification, tier: .safe, explanation: "x", ruleID: "t.foo")

        let selection = SelectionModel()
        selection.selectAllSafe(in: [item])
        let flow = CleanupFlowModel(engine: engine)
        await flow.review(selection.selectedItems(in: [item]))
        guard case .previewing(let plan, _) = flow.state else { return XCTFail("\(flow.state)") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "dry run must not touch the item")
        XCTAssertEqual(plan.executableEntries.count, 1, "\(plan.entries.map(\.blockers))")
        await flow.confirm()
        guard case .finished(let report, _) = flow.state else { return XCTFail("\(flow.state)") }
        XCTAssertEqual(report.results.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: trashDir.path).count, 1)
        XCTAssertFalse(try AuditLog.read(audit).isEmpty)
    }
}
