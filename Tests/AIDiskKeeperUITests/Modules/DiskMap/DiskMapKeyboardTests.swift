import DiskKeeperCore
import XCTest
@testable import DiskKeeperCore
@testable import AIDiskKeeperUI

final class DiskMapKeyboardTests: XCTestCase {
    private let tree = DiskMapFixtures.tree()
    private let viewport = LayoutRect(x: 0, y: 0, width: 800, height: 400)

    private func layouts() -> [(String, DiskMapLayout)] {
        [("strata", DiskMapLayout.strata(tree: tree, focus: tree.rootNodeID, viewport: viewport, options: DiskMapLayoutWorker.strataOptions)),
         ("tiles", DiskMapLayout.tiles(tree: tree, focus: tree.rootNodeID, viewport: viewport, options: DiskMapLayoutWorker.tileOptions))]
    }

    private func id(_ p: String) -> DiskNodeID { DiskMapFixtures.id(p, in: tree) }

    func testArrowsReturnAndEscapeInBothModes() {
        for (name, layout) in layouts() {
            let cc = id(DiskMapFixtures.tool), movies = id("Movies"), loose = id("loose.bin")
            func act(_ sel: DiskNodeID?, _ k: MapKey) -> MapKeyAction {
                DiskMapKeyboard.action(layout: layout, tree: tree, selected: sel, key: k)
            }
            XCTAssertEqual(act(cc, .right), .select(movies), name)
            XCTAssertEqual(act(movies, .left), .select(cc), name)
            XCTAssertEqual(act(cc, .left), .none, "first sibling, \(name)")
            XCTAssertEqual(act(movies, .right), .select(loose), name)
            XCTAssertEqual(act(nil, .down), .select(cc), "nil selection means the focus: \(name)")
            XCTAssertEqual(act(cc, .down), .select(id("\(DiskMapFixtures.tool)/cache")), name)
            XCTAssertEqual(act(loose, .down), .none, "a file has no children: \(name)")
            XCTAssertEqual(act(id("\(DiskMapFixtures.tool)/cache"), .up), .select(cc), name)
            XCTAssertEqual(act(cc, .up), .select(tree.rootNodeID), "up never zooms out: \(name)")
            XCTAssertEqual(act(nil, .up), .none, name)
            XCTAssertEqual(act(cc, .return), .zoomIn(cc), name)
            XCTAssertEqual(act(loose, .return), .none, "files can't be entered: \(name)")
            XCTAssertEqual(act(nil, .return), .none, "the focus is already entered: \(name)")
            XCTAssertEqual(act(cc, .escape), .zoomOut, name)
        }
    }

    func testCanZoomRules() {
        XCTAssertTrue(DiskMapKeyboard.canZoom(into: id("Movies"), tree: tree))
        XCTAssertFalse(DiskMapKeyboard.canZoom(into: id("Movies/m1"), tree: tree))
        XCTAssertFalse(DiskMapKeyboard.canZoom(into: id("loose.bin"), tree: tree))
    }
}
