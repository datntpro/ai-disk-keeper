import DiskKeeperCore
import XCTest
@testable import DiskKeeperCore
@testable import AIDiskKeeperUI

final class DiskMapAccessibilityTests: XCTestCase {
    private func layout(_ t: DiskTree, focus: DiskNodeID? = nil) -> DiskMapLayout {
        DiskMapLayout.strata(tree: t, focus: focus ?? t.rootNodeID, viewport: LayoutRect(x: 0, y: 0, width: 1600, height: 400),
                             options: StrataOptions(rows: 6, minimumWidth: 0.001, rowGap: 1))
    }

    func testRowsAreCappedSortedAndLocalized() {
        let kids = (0..<250).map { SyntheticNode.file("f\($0)", bytes: Int64(1_000_000 - $0 * 100)) }
        let t = DiskTree._synthetic(.dir("r", kids), rootPath: "/tmp/fixture")
        let rows = DiskMapAccessibility.rows(layout: layout(t), tree: t, selection: nil, overlay: nil, rootName: "Home folder")
        XCTAssertEqual(rows.count, 200)
        XCTAssertEqual(rows.map(\.bytes), rows.map(\.bytes).sorted(by: >))
        XCTAssertTrue(rows[0].label.contains("percent of Home folder"), rows[0].label)
        let vi = L10n.withLanguage(.vi) {
            DiskMapAccessibility.rows(layout: layout(t), tree: t, selection: nil, overlay: nil, rootName: "Thư mục Home")[0].label
        }
        XCTAssertTrue(vi.contains("phần trăm của Thư mục Home"), vi)
    }

    func testSelectionAncestorsAreIncludedAndFlagsAreSpoken() {
        let tree = DiskMapFixtures.tree()
        let deep = DiskMapFixtures.id("\(DiskMapFixtures.tool)/sessions/x/x1", in: tree)
        let overlay = DiskMapOverlay.build(tree: tree, items: [ItemFixtures.item("cache")])
        let rows = DiskMapAccessibility.rows(layout: layout(tree), tree: tree, selection: deep, overlay: overlay, rootName: "Home folder")
        let names = rows.map(\.label)
        XCTAssertTrue(names.contains { $0.hasPrefix("x1,") }, "the selection itself")
        XCTAssertTrue(names.contains { $0.hasPrefix("x,") }, "its ancestors")
        XCTAssertTrue(names.contains { $0.hasPrefix(".ssh,") && $0.hasSuffix("protected") })
        let cache = DiskMapAccessibility.rows(layout: layout(tree, focus: DiskMapFixtures.id(DiskMapFixtures.tool, in: tree)),
                                              tree: tree, selection: nil, overlay: overlay, rootName: "Home folder")
        XCTAssertTrue(cache.first { $0.label.hasPrefix("cache,") }!.label.contains("scanner item: Review") ||
                      cache.first { $0.label.hasPrefix("cache,") }!.label.contains("scanner item: Safe"))
        XCTAssertNotNil(cache.first { $0.label.hasPrefix("cache,") }?.reviewItemID)
    }

    func testAllCopyHasVietnamese() {
        L10n.withLanguage(.vi) {
            XCTAssertEqual(DiskMapCopy.scopeHome, "Thư mục Home")
            XCTAssertEqual(DiskMapCopy.a11yRotor, "Thư mục lớn nhất")
            XCTAssertEqual(DiskMapCopy.reviewInList, "Xem trong danh sách")
            XCTAssertEqual(DiskMapCopy.smallItems("3"), "3 mục nhỏ")
            for k in DiskMapCopy.Kind.allCases { XCTAssertFalse(DiskMapCopy.kind(k).isEmpty) }
            for n in DiskMapCopy.Note.allCases { XCTAssertFalse(DiskMapCopy.note(n).hasPrefix("map.")) }
        }
    }
}
