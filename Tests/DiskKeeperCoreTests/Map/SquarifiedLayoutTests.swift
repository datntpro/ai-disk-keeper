import XCTest
@testable import DiskKeeperCore

final class SquarifiedLayoutTests: XCTestCase {
    let vp = LayoutRect(x: 5, y: 7, width: 800, height: 500)

    /// Hand-derived from the published algorithm (rows [6,6] | [4,3] | [2] | [2] | [1]).
    func testKnownExample() {
        let r = SquarifiedLayout.squarify(values: [6, 6, 4, 3, 2, 2, 1], in: LayoutRect(x: 0, y: 0, width: 6, height: 4))
        let e: [(Double, Double, Double, Double)] = [
            (0, 0, 3, 2), (0, 2, 3, 2),
            (3, 0, 12.0 / 7, 7.0 / 3), (3 + 12.0 / 7, 0, 9.0 / 7, 7.0 / 3),
            (3, 7.0 / 3, 1.2, 5.0 / 3), (4.2, 7.0 / 3, 1.2, 5.0 / 3), (5.4, 7.0 / 3, 0.6, 5.0 / 3),
        ]
        XCTAssertEqual(r.count, e.count)
        for (a, b) in zip(r, e) {
            XCTAssertEqual(a.x, b.0, accuracy: 1e-9); XCTAssertEqual(a.y, b.1, accuracy: 1e-9)
            XCTAssertEqual(a.width, b.2, accuracy: 1e-9); XCTAssertEqual(a.height, b.3, accuracy: 1e-9)
        }
    }

    func level1(_ l: DiskMapLayout) -> [MapElement] { l.elements.filter { $0.depth == 1 } }

    func testAreasProportionalAndInside() {
        let t = MapFix.random(seed: 4, depth: 3, fan: 9)
        let o = TileOptions(levels: 1, minimumArea: 0)
        let l = DiskMapLayout.tiles(tree: t, focus: t.rootNodeID, viewport: vp, options: o)
        let kids = level1(l)
        let total = kids.reduce(0) { $0 + Double($1.bytes) }
        for e in kids {
            let scaled = Double(e.bytes) / total * vp.area
            XCTAssertEqual(e.rect.area, scaled, accuracy: max(1, 0.001 * scaled))
            XCTAssertGreaterThanOrEqual(e.rect.x, vp.x - 1e-9); XCTAssertLessThanOrEqual(e.rect.maxX, vp.maxX + 1e-9)
            XCTAssertGreaterThanOrEqual(e.rect.y, vp.y - 1e-9); XCTAssertLessThanOrEqual(e.rect.maxY, vp.maxY + 1e-9)
        }
        MapFix.assertFinite(l)
    }

    func testTilesInsideParentAndNoOverlap() {
        let t = MapFix.random(seed: 5, depth: 3, fan: 12)
        let l = DiskMapLayout.tiles(tree: t, focus: t.rootNodeID, viewport: vp)
        let drawn = l.elements.filter { $0.depth > 0 }
        XCTAssertLessThanOrEqual(drawn.count, 300)
        for i in drawn.indices {
            for j in drawn.indices where j > i {
                let a = drawn[i], b = drawn[j]
                if a.depth != b.depth { continue }
                XCTAssertLessThanOrEqual(MapFix.intersectionArea(a.rect, b.rect), 1e-6)
            }
        }
        for e in l.elements where e.depth == 2 {
            guard case .node(let n) = e.kind, let p = t.node(n).parent, let pe = l.element(for: p) else { continue }
            XCTAssertLessThanOrEqual(MapFix.intersectionArea(e.rect, pe.rect), e.rect.area + 1e-6)
            XCTAssertEqual(MapFix.intersectionArea(e.rect, pe.rect), e.rect.area, accuracy: 1e-6)
        }
    }

    func testAspectRatiosBetterThanSliceAndDice() {
        var g = SplitMix64(seed: 77)
        let vals = (0..<40).map { _ in Double(Int.random(in: 1...1000, using: &g)) }.sorted(by: >)
        let total = vals.reduce(0, +)
        let scaled = vals.map { $0 / total * vp.area }
        func ar(_ r: LayoutRect) -> Double { max(r.width / r.height, r.height / r.width) }
        let sq = SquarifiedLayout.squarify(values: scaled, in: vp)
        var x = vp.x
        let slice = scaled.map { v -> LayoutRect in let w = v / vp.height; defer { x += w }; return LayoutRect(x: x, y: vp.y, width: w, height: vp.height) }
        let m1 = sq.map(ar).reduce(0, +) / 40, m2 = slice.map(ar).reduce(0, +) / 40
        XCTAssertLessThan(m1, m2)
    }

    func testThinViewportTerminates() {
        let t = MapFix.random(seed: 6, depth: 2, fan: 20)
        let l = DiskMapLayout.tiles(tree: t, focus: t.rootNodeID, viewport: LayoutRect(x: 0, y: 0, width: 2000, height: 20))
        MapFix.assertFinite(l)
        XCTAssertGreaterThan(l.elements.count, 1)
    }

    func testLevelTwoInsideInsetAndHeader() {
        let t = MapFix.tree([.dir("a", [.file("x", bytes: 600), .file("y", bytes: 400)]), .file("b", bytes: 1000)])
        let o = TileOptions()
        let l = DiskMapLayout.tiles(tree: t, focus: t.rootNodeID, viewport: vp, options: o)
        let a = t.children(of: t.rootNodeID).first { t.node($0).name == "a" }!
        let ae = l.element(for: a)!
        let kids = MapFix.children(l, of: a, t)
        XCTAssertEqual(kids.count, 2)
        let box = ae.rect.inset(by: o.padding)
        for k in kids {
            XCTAssertGreaterThanOrEqual(k.rect.x, box.x - 1e-9)
            XCTAssertLessThanOrEqual(k.rect.maxX, box.maxX + 1e-9)
            XCTAssertGreaterThanOrEqual(k.rect.y, box.y + o.headerHeight - 1e-9)
            XCTAssertLessThanOrEqual(k.rect.maxY, box.maxY + 1e-9)
            XCTAssertEqual(k.depth, 2)
        }
        let one = DiskMapLayout.tiles(tree: t, focus: t.rootNodeID, viewport: vp, options: TileOptions(levels: 1))
        XCTAssertEqual(one.elements.map(\.depth).max(), 1)
        XCTAssertTrue(one.element(for: a)!.hasHiddenChildren)
    }

    func testOwnBytesGapLeavesEmptySpace() {
        var d = SyntheticNode.dir("a", [.file("x", bytes: 500)])
        d.allocatedBytes = 500                       // total 1000, half is own blocks
        let t = MapFix.tree([d, .file("b", bytes: 1000)])
        let o = TileOptions(levels: 2, minimumArea: 0, padding: 0, headerHeight: 0)
        let l = DiskMapLayout.tiles(tree: t, focus: t.rootNodeID, viewport: vp, options: o)
        let a = t.children(of: t.rootNodeID).first { t.node($0).name == "a" }!
        let ae = l.element(for: a)!
        let x = MapFix.children(l, of: a, t)[0]
        XCTAssertEqual(x.rect.area, ae.rect.area / 2, accuracy: 1e-6)
        // a point in the unused half returns the level-1 element
        let probe = LayoutPoint(x: ae.rect.maxX - 0.001, y: ae.rect.maxY - 0.001)
        let hit = l.element(at: probe)
        XCTAssertTrue(hit?.rect == ae.rect || hit?.rect == x.rect)
        XCTAssertLessThan(x.rect.area, ae.rect.area)
    }

    func testMinimumAreaAggregate() {
        var kids: [SyntheticNode] = [.file("big", bytes: 1_000_000)]
        for i in 0..<20 { kids.append(.file("s\(i)", bytes: 10)) }
        let t = MapFix.tree(kids)
        let l = DiskMapLayout.tiles(tree: t, focus: t.rootNodeID, viewport: vp)
        let aggs = l.elements.filter { if case .aggregate = $0.kind { return true } else { return false } }
        XCTAssertEqual(aggs.count, 1)
        guard case .aggregate(_, let count, let bytes) = aggs[0].kind else { return XCTFail() }
        XCTAssertEqual(count, 20); XCTAssertEqual(bytes, 200)
        XCTAssertTrue(l.elements[0].hasHiddenChildren)
    }

    func testDegenerateAndEmpty() {
        let t = MapFix.tree([.file("a", bytes: 1)])
        XCTAssertTrue(DiskMapLayout.tiles(tree: t, focus: t.rootNodeID, viewport: LayoutRect(x: 0, y: 0, width: 0, height: 5)).elements.isEmpty)
        XCTAssertTrue(DiskMapLayout.tiles(tree: t, focus: t.rootNodeID, viewport: LayoutRect(x: 0, y: 0, width: .infinity, height: 5)).elements.isEmpty)
        let e = MapFix.tree([])
        let l = DiskMapLayout.tiles(tree: e, focus: e.rootNodeID, viewport: vp)
        XCTAssertEqual(l.elements.count, 1)
        XCTAssertFalse(l.elements[0].hasHiddenChildren)
        let s = MapFix.tree([.file("only", bytes: 9)])
        let ls = DiskMapLayout.tiles(tree: s, focus: s.rootNodeID, viewport: vp)
        XCTAssertEqual(ls.elements[1].rect, vp)
    }

    func testDeterministic() {
        let t = MapFix.random(seed: 8, depth: 4, fan: 7)
        XCTAssertEqual(DiskMapLayout.tiles(tree: t, focus: t.rootNodeID, viewport: vp).elements,
                       DiskMapLayout.tiles(tree: t, focus: t.rootNodeID, viewport: vp).elements)
    }
}
