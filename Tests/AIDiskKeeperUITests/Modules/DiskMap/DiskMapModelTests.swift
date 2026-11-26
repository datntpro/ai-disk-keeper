import DiskKeeperCore
import XCTest
@testable import DiskKeeperCore
@testable import AIDiskKeeperUI

@MainActor
final class DiskMapModelTests: XCTestCase {
    func testStartsAtRootWithLayoutAndBreadcrumbs() async {
        let tree = DiskMapFixtures.tree()
        let m = await DiskMapHarness.model(tree: tree)
        XCTAssertEqual(m.focusID, tree.rootNodeID)
        XCTAssertNotNil(m.layout)
        XCTAssertEqual(m.breadcrumbs.map(\.name), ["fixture"])
        XCTAssertEqual(m.paints.count, m.layout?.elements.count)
    }

    func testZoomZoomOutAndCrumbUpdateFocusAndBreadcrumbs() async {
        let tree = DiskMapFixtures.tree()
        let m = await DiskMapHarness.model(tree: tree)
        let cc = DiskMapFixtures.id(DiskMapFixtures.tool, in: tree)
        let cache = DiskMapFixtures.id("\(DiskMapFixtures.tool)/cache", in: tree)
        m.zoom(into: cc)
        await m.waitForLayout()
        XCTAssertEqual(m.focusID, cc)
        m.zoom(into: cache)
        await m.waitForLayout()
        XCTAssertEqual(m.breadcrumbs.map(\.name), ["fixture", DiskMapFixtures.tool, "cache"])
        XCTAssertNotNil(m.transition, "zooming animates")
        XCTAssertTrue(m.zoomOut())
        await m.waitForLayout()
        XCTAssertEqual(m.focusID, cc)
        XCTAssertEqual(m.selectedNode, cache, "zooming out selects where we came from")
        m.zoom(toCrumb: tree.rootNodeID)
        await m.waitForLayout()
        XCTAssertEqual(m.focusID, tree.rootNodeID)
        XCTAssertEqual(m.breadcrumbs.count, 1)
    }

    func testZoomIntoFileOrSmallItemsIsRefused() async {
        let tree = DiskMapFixtures.tree()
        let m = await DiskMapHarness.model(tree: tree)
        m.zoom(into: DiskMapFixtures.id("loose.bin", in: tree))
        XCTAssertEqual(m.focusID, tree.rootNodeID)
        m.zoom(into: DiskMapFixtures.id("Movies/m1", in: tree))
        XCTAssertEqual(m.focusID, tree.rootNodeID)
    }

    func testClickingAnAggregateDoesNothing() async {
        let tree = DiskMapFixtures.aggregateTree()
        let m = await DiskMapHarness.model(tree: tree)
        let agg = m.layout!.elements.first { if case .aggregate = $0.kind { return true } else { return false } }
        let aggregate = try! XCTUnwrap(agg)
        let before = m.selectedNode
        m.click(CGPoint(x: aggregate.rect.x + aggregate.rect.width / 2, y: aggregate.rect.y + aggregate.rect.height / 2))
        m.click(CGPoint(x: aggregate.rect.x + aggregate.rect.width / 2, y: aggregate.rect.y + aggregate.rect.height / 2))
        XCTAssertEqual(m.focusID, tree.rootNodeID)
        XCTAssertEqual(m.selectedNode, before)
        XCTAssertEqual(m.contextTarget, nil)
        m.hover(CGPoint(x: aggregate.rect.x + 0.5, y: aggregate.rect.y + 1))
        XCTAssertEqual(m.contextTarget?.canZoom, false)
    }

    func testEscapeAtRootIsNoOpAndReturnsFalse() async {
        let m = await DiskMapHarness.model(tree: DiskMapFixtures.tree())
        let before = m.layoutRequestCount
        XCTAssertFalse(m.handleKey(.escape))
        XCTAssertFalse(m.zoomOut())
        XCTAssertEqual(m.layoutRequestCount, before)
    }

    func testSecondClickOnSelectedDirectoryZooms() async {
        let tree = DiskMapFixtures.tree()
        let m = await DiskMapHarness.model(tree: tree)
        let cc = DiskMapFixtures.id(DiskMapFixtures.tool, in: tree)
        let p = DiskMapHarness.center(of: cc, in: m)
        m.click(p)
        XCTAssertEqual(m.selectedNode, cc)
        XCTAssertEqual(m.focusID, tree.rootNodeID)
        m.click(p)
        XCTAssertEqual(m.focusID, cc)
    }

    func testNewTreeKeepsFocusByPathOrResets() async {
        let tree = DiskMapFixtures.tree()
        let fake1 = FakeDiskIndexer(), fake2 = FakeDiskIndexer()
        let box = TwoFakes([fake1, fake2])
        let index = DiskIndexModel(makeIndexer: { box.next() }, fullDiskAccess: { false }, minProgressInterval: .zero)
        let m = DiskMapModel(index: index, scanItems: { [] }, debounce: .milliseconds(1))
        index.start(.home)
        await wait { await fake1.isWaiting }
        await fake1.finish(tree)
        await wait { index.phase == .ready }
        m.treeChanged(); m.viewportChanged(CGSize(width: 800, height: 400)); await m.waitForLayout()
        let cc = DiskMapFixtures.id(DiskMapFixtures.tool, in: tree)
        m.zoom(into: cc); await m.waitForLayout()

        // A new tree that still has the folder keeps the focus (by path, not by id).
        index.start(.home)
        await wait { await fake2.isWaiting }
        await fake2.finish(DiskMapFixtures.tree())
        await wait { index.generation == 2 }
        m.treeChanged(); await m.waitForLayout()
        XCTAssertEqual(m.tree?.path(of: m.focusID!), "/tmp/fixture/\(DiskMapFixtures.tool)")
        XCTAssertNil(m.hoveredElement)

        // A new tree without it goes back to the root.
        let fake3 = FakeDiskIndexer()
        box.add(fake3)
        index.start(.home)
        await wait { await fake3.isWaiting }
        await fake3.finish(DiskTree._synthetic(.dir("r", [.dir("Other", [.file("o", bytes: 5)])]), rootPath: "/tmp/fixture"))
        await wait { index.generation == 3 }
        m.treeChanged(); await m.waitForLayout()
        XCTAssertEqual(m.focusID, m.tree?.rootNodeID)
    }

    func testStaleLayoutResultsAreDropped() async {
        let tree = DiskMapFixtures.tree()
        let m = await DiskMapHarness.model(tree: tree)
        let old = m.layout!
        let staleToken = m.layoutToken
        m.setMode(.tiles)
        await m.waitForLayout()
        let current = m.layout!
        m.apply(old, token: staleToken, from: nil)
        if case .tiles = m.layout!.mode {} else { XCTFail("a stale strata result replaced the tiles layout") }
        XCTAssertEqual(m.layout!.elements.count, current.elements.count)
    }

    func testHoverNeverRequestsALayout() async {
        let m = await DiskMapHarness.model(tree: DiskMapFixtures.tree())
        let before = m.layoutRequestCount
        for x in stride(from: 0.0, to: 800, by: 7) { m.hover(CGPoint(x: x, y: 20)) }
        m.hover(nil)
        XCTAssertEqual(m.layoutRequestCount, before)
    }

    func testOverlayRebuildsOnScanChange() async {
        let tree = DiskMapFixtures.tree()
        var items: [ScanItem] = []
        let (index, _) = await DiskMapHarness.index(with: tree)
        let m = DiskMapModel(index: index, scanItems: { items }, debounce: .milliseconds(1))
        m.treeChanged(); m.viewportChanged(CGSize(width: 800, height: 400)); await m.waitForLayout(); await m.waitForOverlay()
        let cache = DiskMapFixtures.id("\(DiskMapFixtures.tool)/cache", in: tree)
        XCTAssertNil(m.overlay?.attribution(cache))
        XCTAssertFalse(m.hasScanItems)
        items = [ItemFixtures.item("cache", size: 500)]
        m.scanChanged()
        await m.waitForOverlay()
        XCTAssertNotNil(m.overlay?.attribution(cache))
        XCTAssertTrue(m.hasScanItems)
    }

    func testFilterDimsWithoutChangingLayout() async {
        let tree = DiskMapFixtures.tree()
        let m = await DiskMapHarness.model(tree: tree)
        let before = m.layout!.elements.map(\.rect)
        let requests = m.layoutRequestCount
        m.setFilterText("movie")
        let hits = try! XCTUnwrap(m.matchingElements)
        XCTAssertEqual(hits, [m.layout!.element(for: DiskMapFixtures.id("Movies", in: tree))!.id])
        XCTAssertEqual(m.layout!.elements.map(\.rect), before)
        XCTAssertEqual(m.layoutRequestCount, requests)
        m.setFilterText("")
        XCTAssertNil(m.matchingElements)
    }

    func testTooltipAppearsAfterDwell() async {
        let tree = DiskMapFixtures.tree()
        let m = await DiskMapHarness.model(tree: tree)
        let p = DiskMapHarness.center(of: DiskMapFixtures.id("Movies", in: tree), in: m)
        m.hover(p)
        XCTAssertNil(m.tooltipElement)
        for _ in 0..<100 { if m.tooltipElement != nil { break }; try? await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertNotNil(m.tooltipElement)
        m.hover(nil)
        XCTAssertNil(m.tooltipElement)
    }

    func testSelectionAnnouncesName() async {
        var said: [String] = []
        let tree = DiskMapFixtures.tree()
        let m = await DiskMapHarness.model(tree: tree, announce: { said.append($0) })
        m.select(DiskMapFixtures.id("Movies", in: tree))
        XCTAssertEqual(said.count, 1)
        XCTAssertTrue(said[0].hasPrefix("Movies, "), said[0])
        XCTAssertTrue(said[0].contains("percent of"))
    }

    func testTilesModeProducesALayoutToo() async {
        let m = await DiskMapHarness.model(tree: DiskMapFixtures.tree(), mode: .tiles)
        if case .tiles = m.layout!.mode {} else { XCTFail("expected tiles") }
    }

    private func wait(_ cond: @MainActor () async -> Bool) async {
        for _ in 0..<600 { if await cond() { return }; try? await Task.sleep(nanoseconds: 5_000_000) }
    }
}

private final class TwoFakes: @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [FakeDiskIndexer]
    init(_ q: [FakeDiskIndexer]) { queue = q }
    func next() -> FakeDiskIndexer { lock.lock(); defer { lock.unlock() }; return queue.removeFirst() }
    func add(_ f: FakeDiskIndexer) { lock.lock(); queue.append(f); lock.unlock() }
}
