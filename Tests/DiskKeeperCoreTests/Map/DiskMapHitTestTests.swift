import XCTest
@testable import DiskKeeperCore

final class DiskMapHitTestTests: XCTestCase {
    let vp = LayoutRect(x: 0, y: 0, width: 1000, height: 300)

    func testStrataBasics() {
        var kids: [SyntheticNode] = [.file("a", bytes: 500_000), .file("b", bytes: 499_000)]
        kids.append(.file("tiny", bytes: 2000))      // 2 pt wide
        let t = MapFix.tree(kids)
        let l = DiskMapLayout.strata(tree: t, focus: t.rootNodeID, viewport: vp)
        let a = t.children(of: t.rootNodeID).first { t.node($0).name == "a" }!
        let ae = l.element(for: a)!
        XCTAssertEqual(l.element(at: LayoutPoint(x: ae.rect.x + 1, y: ae.rect.y + 1))?.kind, .node(a))
        // shared edge → right-hand element
        let b = l.elements.first { $0.rect.x == ae.rect.maxX && $0.depth == 1 }!
        XCTAssertEqual(l.element(at: LayoutPoint(x: ae.rect.maxX, y: ae.rect.y + 1))?.id, b.id)
        // row gap and outside → nil
        XCTAssertNil(l.element(at: LayoutPoint(x: 5, y: ae.rect.y - 0.5)))
        XCTAssertNil(l.element(at: LayoutPoint(x: -1, y: 1)))
        XCTAssertNil(l.element(at: LayoutPoint(x: 1000, y: 1)))
        XCTAssertNil(l.element(at: LayoutPoint(x: 5, y: 300)))
        XCTAssertNil(l.element(at: LayoutPoint(x: .nan, y: 5)))
        // the tiny node is hittable
        let tiny = l.elements.first { $0.rect.width < 3 && $0.depth == 1 }!
        XCTAssertEqual(l.element(at: LayoutPoint(x: tiny.rect.x + tiny.rect.width / 2, y: tiny.rect.y + 1))?.id, tiny.id)
    }

    func testHugeFiniteCoordinatesDoNotTrap() {
        let t = MapFix.tree([.file("a", bytes: 10)])
        let l = DiskMapLayout.strata(tree: t, focus: t.rootNodeID, viewport: vp)
        for y in [1e300, -1e300, Double.greatestFiniteMagnitude, 1e19, 9.3e18] {
            XCTAssertNil(l.element(at: LayoutPoint(x: 5, y: y)))
        }
        XCTAssertNil(l.element(at: LayoutPoint(x: 5, y: .infinity)))
        let tiles = DiskMapLayout.tiles(tree: t, focus: t.rootNodeID, viewport: vp)
        XCTAssertNil(tiles.element(at: LayoutPoint(x: 5, y: 1e300)))
    }

    func testStrataAggregateHit() {
        var kids: [SyntheticNode] = [.file("big", bytes: 1_000_000)]
        for i in 0..<10 { kids.append(.file("s\(i)", bytes: 400)) }
        let t = MapFix.tree(kids)
        let l = DiskMapLayout.strata(tree: t, focus: t.rootNodeID, viewport: vp)
        let agg = l.elements.first { if case .aggregate = $0.kind { return true } else { return false } }!
        let hit = l.element(at: LayoutPoint(x: agg.rect.x + agg.rect.width / 2, y: agg.rect.y + 1))
        guard case .aggregate = hit?.kind else { return XCTFail("\(String(describing: hit))") }
    }

    func testTilesLevels() {
        var d = SyntheticNode.dir("a", [.file("x", bytes: 300), .file("y", bytes: 200)])
        d.allocatedBytes = 500
        let t = MapFix.tree([d, .file("b", bytes: 1000)])
        let o = TileOptions(levels: 2, minimumArea: 0, padding: 2, headerHeight: 16)
        let l = DiskMapLayout.tiles(tree: t, focus: t.rootNodeID, viewport: vp, options: o)
        let a = t.children(of: t.rootNodeID).first { t.node($0).name == "a" }!
        let ae = l.element(for: a)!
        let x = MapFix.children(l, of: a, t)[0]
        XCTAssertEqual(l.element(at: LayoutPoint(x: x.rect.x + 1, y: x.rect.y + 1))?.id, x.id)
        XCTAssertEqual(l.element(at: LayoutPoint(x: ae.rect.x + 5, y: ae.rect.y + 5))?.id, ae.id)   // header
        XCTAssertNil(l.element(at: LayoutPoint(x: 1000, y: 0)))
    }

    private func brute(_ l: DiskMapLayout, _ p: LayoutPoint) -> MapElement? {
        l.elements.filter { $0.rect.contains(p) }.max { $0.depth < $1.depth }
    }

    func testHitTestMatchesBruteForce() {
        let t = MapFix.random(seed: 21, depth: 4, fan: 8)
        var g = SplitMix64(seed: 5)
        for mode in 0..<2 {
            let l = mode == 0 ? DiskMapLayout.strata(tree: t, focus: t.rootNodeID, viewport: vp)
                              : DiskMapLayout.tiles(tree: t, focus: t.rootNodeID, viewport: vp)
            for _ in 0..<10_000 {
                let p = LayoutPoint(x: Double.random(in: -10...1010, using: &g), y: Double.random(in: -10...310, using: &g))
                let expected = brute(l, p)
                let got = l.element(at: p)
                if mode == 0 { XCTAssertEqual(got?.id, expected?.id, "\(p)") }
                else if let e = expected { XCTAssertEqual(got?.id, e.id, "\(p)") } else { XCTAssertNil(got) }
            }
        }
    }
}
