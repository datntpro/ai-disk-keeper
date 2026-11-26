import DiskKeeperCore
import XCTest
@testable import DiskKeeperCore
@testable import AIDiskKeeperUI

final class DiskMapInspectorTests: XCTestCase {
    private let tree = DiskMapFixtures.tree()

    private func info(_ path: String?, focus: String? = nil, items: [ScanItem] = []) -> InspectorInfo {
        let overlay = DiskMapOverlay.build(tree: tree, items: items)
        let node = path.map { DiskMapFixtures.id($0, in: tree) } ?? tree.rootNodeID
        let f = focus.map { DiskMapFixtures.id($0, in: tree) } ?? tree.rootNodeID
        return DiskMapInspector.info(tree: tree, node: node, focus: f, overlay: overlay, rootName: "Home folder")
    }

    func testSharesAndLargestFive() {
        let i = info(DiskMapFixtures.tool)
        XCTAssertEqual(i.bytes, 750)
        XCTAssertEqual(i.shareOfParent!, 750.0 / 1410.0, accuracy: 1e-9)
        XCTAssertEqual(i.shareOfFocus!, i.shareOfParent!, accuracy: 1e-9)
        XCTAssertEqual(i.largest.map(\.name), ["cache", "sessions", "notes.txt"])
        XCTAssertEqual(i.largest.map(\.bytes), [500, 200, 50])
        let inner = info("\(DiskMapFixtures.tool)/cache", focus: DiskMapFixtures.tool)
        XCTAssertEqual(inner.shareOfFocus!, 500.0 / 750.0, accuracy: 1e-9)
        XCTAssertEqual(inner.shareOfParent!, 500.0 / 750.0, accuracy: 1e-9)
        XCTAssertEqual(inner.focusName, DiskMapFixtures.tool)
        XCTAssertNil(info(nil).shareOfParent, "the root has no parent")
    }

    func testLargestIsCappedAtFive() {
        let kids = (0..<9).map { SyntheticNode.file("f\($0)", bytes: Int64(100 - $0)) }
        let t = DiskTree._synthetic(.dir("r", kids), rootPath: "/tmp/fixture")
        let i = DiskMapInspector.info(tree: t, node: t.rootNodeID, focus: t.rootNodeID, overlay: nil, rootName: "x")
        XCTAssertEqual(i.largest.count, 5)
        XCTAssertEqual(i.largest.map(\.bytes), [100, 99, 98, 97, 96])
    }

    func testExactAndInsideAttributionChooseActions() {
        let exact = info("\(DiskMapFixtures.tool)/cache", items: [ItemFixtures.item("cache")])
        XCTAssertEqual(exact.actions, [.reviewInList, .revealInFinder])
        if case .exact = exact.classification {} else { XCTFail("expected exact") }
        XCTAssertNotNil(exact.reviewItemID)

        // An item deeper than the materialized tree lands on the nearest node, not exact.
        let deeper = ItemFixtures.item("cache/deeper/inside")
        let inside = info("\(DiskMapFixtures.tool)/cache", items: [deeper])
        if case .inside = inside.classification {} else { XCTFail("expected inside, got \(inside.classification)") }
        XCTAssertEqual(inside.actions, [.reviewInList, .revealInFinder])

        let none = info("Movies", items: [ItemFixtures.item("cache")])
        XCTAssertEqual(none.classification, .unclassified)
        XCTAssertEqual(none.actions, [.revealInFinder])
    }

    func testNoDestructiveActionExists() {
        XCTAssertEqual(Set(InspectorInfo.Action.allCases), [.reviewInList, .revealInFinder])
    }

    func testProtectedKindAndSmallItemsReveal() {
        let ssh = info(".ssh")
        XCTAssertTrue(ssh.isProtected)
        XCTAssertEqual(ssh.kind, .folder)
        XCTAssertEqual(info("loose.bin").kind, .file)
    }

    func testLogicalSizeOnlyWhenItDiffers() {
        let t = DiskTree._synthetic(.dir("r", [.file("sparse", bytes: 100, logical: 1000), .file("same", bytes: 100, logical: 105)]),
                                    rootPath: "/tmp/fixture")
        let sparse = DiskMapInspector.info(tree: t, node: t.lookup(path: "/tmp/fixture/sparse")!, focus: t.rootNodeID, overlay: nil, rootName: "x")
        let same = DiskMapInspector.info(tree: t, node: t.lookup(path: "/tmp/fixture/same")!, focus: t.rootNodeID, overlay: nil, rootName: "x")
        XCTAssertEqual(sparse.logicalBytes, 1000)
        XCTAssertNil(same.logicalBytes)
    }
}
