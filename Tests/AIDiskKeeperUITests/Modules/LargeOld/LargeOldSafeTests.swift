import DiskKeeperCore
import XCTest
@testable import AIDiskKeeperUI

@MainActor
final class LargeOldSafeTests: XCTestCase {
    private func model() -> LargeOldModel {
        LargeOldModel(index: DiskIndexModel(makeIndexer: { throw DiskIndexUnavailable() }, fullDiskAccess: { false }),
                      scanner: { _ in LargeOldFix.report() }, now: { LargeOldFix.now })
    }

    func testNoItemIsEverSafeAndSelectAllSafeSelectsNothing() {
        let m = model()
        let items = LargeOldFix.sample.map(m.item(for:))
        XCTAssertFalse(items.isEmpty)
        for item in items {
            XCTAssertEqual(item.tier, .review)
            XCTAssertFalse(item.isBulkSelectable)
        }
        m.selection.selectAllSafe(in: items)
        XCTAssertTrue(m.selection.selectedIDs.isEmpty)
    }

    func testReportOnlyRowsAreNotSelectable() {
        let m = model()
        let linked = m.item(for: LargeOldFix.file("x.bin", mb: 700, links: 2))
        XCTAssertEqual(linked.cleanupMethod, CleanupMethod.none)
        m.selection.setSelected(linked, true)
        XCTAssertTrue(m.selection.selectedIDs.isEmpty)
    }

    func testViewSourcesHaveNoSelectAllControls() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/AIDiskKeeperUI/Modules/LargeOld")
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".swift") }
        XCTAssertGreaterThanOrEqual(files.count, 8)
        for f in files {
            let text = try String(contentsOf: dir.appendingPathComponent(f), encoding: .utf8)
            for banned in ["SelectAllSafeButton", "selectAllSafe", "removeItem", "trashItem", "CleanupEngine("] {
                XCTAssertFalse(text.contains(banned), "\(f) mentions \(banned)")
            }
        }
    }
}
