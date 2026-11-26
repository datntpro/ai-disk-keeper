import DiskKeeperCore
import SwiftUI
import XCTest
@testable import AIDiskKeeperUI

@MainActor
final class LargeOldMountedTests: XCTestCase {
    private func model(_ files: [LargeFile]) -> LargeOldModel {
        let index = DiskIndexModel(makeIndexer: { throw DiskIndexUnavailable() }, fullDiskAccess: { false })
        let m = LargeOldModel(index: index, scanner: { _ in LargeOldFix.report(files) }, now: { LargeOldFix.now })
        m.adopt(LargeOldFix.report(files), generation: 1)
        return m
    }

    func testMountedImageIsKeepUnselectableAndOutOfTotals() {
        let mounted = LargeOldFix.file("Downloads/Mounted.dmg", mb: 900, kind: .diskImageOrInstaller, mounted: true)
        let plain = LargeOldFix.file("Downloads/Plain.dmg", mb: 700, kind: .diskImageOrInstaller)
        let m = model([mounted, plain])
        let item = m.item(for: mounted)
        XCTAssertEqual(item.tier, .keep)
        XCTAssertFalse(item.isSelectable)
        XCTAssertTrue(m.item(for: plain).isSelectable)
        for f in m.rows { m.selection.setSelected(m.item(for: f), true) }
        XCTAssertEqual(m.selectedItems.map(\.displayName), ["Plain.dmg"])
        XCTAssertEqual(m.badgeBytes, 700_000_000)
        XCTAssertEqual(m.kindTotals[.diskImageOrInstaller]?.count, 1)
        XCTAssertEqual(m.kindTotals[.diskImageOrInstaller]?.bytes, 700_000_000)
    }

    func testRowTextAndBadge() {
        let now = LargeOldFix.now
        let mounted = LargeOldFix.file("a/M.dmg", mb: 900, kind: .diskImageOrInstaller, mounted: true)
        XCTAssertEqual(LargeOldCopy.mountedImage, "Mounted disk image: eject it first")
        XCTAssertEqual(LargeOldCopy.explanation(mounted, now: now), "Mounted disk image: eject it first")
        let archive = LargeOldFix.file("a/Z.zip", mb: 900, kind: .archive, months: 14)
        let text = LargeOldCopy.explanation(archive, now: now)
        XCTAssertFalse(text.hasPrefix("A archive"))
        XCTAssertTrue(text.hasPrefix("Last opened "))
        XCTAssertTrue(text.contains("Moving it to the Trash frees up to"))
        // A row is a pill-free file cell unless it shares, hints or is mounted.
        XCTAssertFalse(archive.showsSharedStoragePill)
        XCTAssertTrue(mounted.isMountedImage)
        let table = LargeOldTable(model: model([mounted, archive]))
        XCTAssertNotNil(ImageRenderer(content: table.frame(width: 900, height: 300)).cgImage)
    }
}
