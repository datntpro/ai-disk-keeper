import XCTest
@testable import DiskKeeperCore

final class StrataLayoutTests: XCTestCase {
    let vp = LayoutRect(x: 10, y: 20, width: 1000, height: 300)

    func parentElement(_ l: DiskMapLayout, _ t: DiskTree, _ id: DiskNodeID) -> MapElement? {
        t.node(id).parent.flatMap { l.element(for: $0) }
    }

    func testWidthsProportionalWithin1pt() {
        let t = MapFix.random(seed: 1, depth: 4, fan: 6)
        let l = DiskMapLayout.strata(tree: t, focus: t.rootNodeID, viewport: vp)
        for e in l.elements {
            guard case .node(let n) = e.kind, let p = parentElement(l, t, n), p.bytes > 0 else { continue }
            let expect = p.rect.width * Double(e.bytes) / Double(p.bytes)
            XCTAssertEqual(e.rect.width, expect, accuracy: 1.0)
        }
    }

    func testChildrenInsideParentAndNoOverlap() {
        let t = MapFix.random(seed: 2, depth: 4, fan: 8)
        let o = StrataOptions()
        let l = DiskMapLayout.strata(tree: t, focus: t.rootNodeID, viewport: vp, options: o)
        let h = (vp.height - Double(o.rows - 1) * o.rowGap) / Double(o.rows)
        for e in l.elements {
            XCTAssertEqual(e.rect.y, vp.y + Double(e.depth) * (h + o.rowGap), accuracy: 1e-9)
            XCTAssertGreaterThanOrEqual(e.rect.x, vp.x - 1e-9)
            XCTAssertLessThanOrEqual(e.rect.maxX, vp.maxX + 1e-9)
            if case .node(let n) = e.kind, let p = parentElement(l, t, n) {
                XCTAssertGreaterThanOrEqual(e.rect.x, p.rect.x - 1e-9)
                XCTAssertLessThanOrEqual(e.rect.maxX, p.rect.maxX + 1e-9)
            }
        }
        for d in 0..<o.rows {
            let row = l.elements.filter { $0.depth == d }
            for (a, b) in zip(row, row.dropFirst()) { XCTAssertLessThanOrEqual(a.rect.maxX, b.rect.x + 1e-9) }
        }
        // draw order: row-major, parents first
        XCTAssertEqual(l.elements.map(\.depth), l.elements.map(\.depth).sorted())
        XCTAssertEqual(l.elements.map(\.id), Array(l.elements.indices))
    }

    func testRowLimitAndHiddenChildren() {
        let t = MapFix.tree([.dir("a", [.dir("b", [.file("c", bytes: 1000)])])])
        let l = DiskMapLayout.strata(tree: t, focus: t.rootNodeID, viewport: vp, options: .init(rows: 2))
        XCTAssertEqual(l.elements.map(\.depth).max(), 1)
        XCTAssertTrue(l.elements.first { $0.depth == 1 }!.hasHiddenChildren)
        XCTAssertFalse(l.elements[0].hasHiddenChildren)
        let one = DiskMapLayout.strata(tree: t, focus: t.rootNodeID, viewport: vp, options: .init(rows: 1))
        XCTAssertEqual(one.elements.count, 1)
        XCTAssertTrue(one.elements[0].hasHiddenChildren)
    }

    func testTinyChildrenMergeIntoOneAggregatePerParent() {
        var kids: [SyntheticNode] = [.file("big", bytes: 1_000_000)]
        for i in 0..<10 { kids.append(.file("s\(i)", bytes: 100)) }
        let t = MapFix.tree(kids)
        let l = DiskMapLayout.strata(tree: t, focus: t.rootNodeID, viewport: vp)
        let aggs = l.elements.filter { if case .aggregate = $0.kind { return true } else { return false } }
        XCTAssertEqual(aggs.count, 1)
        guard case .aggregate(let parent, let count, let bytes) = aggs[0].kind else { return XCTFail() }
        XCTAssertEqual(parent, t.rootNodeID); XCTAssertEqual(count, 10); XCTAssertEqual(bytes, 1000)
        XCTAssertTrue(l.elements[0].hasHiddenChildren)
        XCTAssertEqual(aggs[0].depth, 1)
    }

    func testElementBound() {
        let o = StrataOptions()
        for seed in 1...5 as ClosedRange<UInt64> {
            let t = MapFix.random(seed: seed, depth: 5, fan: 8)
            let l = DiskMapLayout.strata(tree: t, focus: t.rootNodeID, viewport: vp, options: o)
            XCTAssertLessThanOrEqual(Double(l.elements.count), Double(o.rows) * vp.width / o.minimumWidth + Double(o.rows))
        }
        let many = MapFix.tree((0..<10_000).map { .file("f\($0)", bytes: 4096) })
        let l = DiskMapLayout.strata(tree: many, focus: many.rootNodeID, viewport: vp)
        XCTAssertLessThanOrEqual(l.elements.count, 6 * 500 + 6)
        XCTAssertEqual(l.elements.count, 2)   // each child is 0.1 pt wide: focus + one aggregate
        let few = MapFix.tree((0..<300).map { .file("f\($0)", bytes: 4096) })
        XCTAssertEqual(DiskMapLayout.strata(tree: few, focus: few.rootNodeID, viewport: vp).elements.count, 301)
    }

    func testDeterministic() {
        let t = MapFix.random(seed: 9, depth: 4, fan: 7)
        let a = DiskMapLayout.strata(tree: t, focus: t.rootNodeID, viewport: vp)
        let b = DiskMapLayout.strata(tree: t, focus: t.rootNodeID, viewport: vp)
        XCTAssertEqual(a.elements, b.elements)
    }

    func testZeroAndDegenerateViewports() {
        let t = MapFix.random(seed: 3, depth: 3, fan: 4)
        for r in [LayoutRect(x: 0, y: 0, width: 0, height: 100), LayoutRect(x: 0, y: 0, width: 100, height: 0),
                  LayoutRect(x: 0, y: 0, width: -5, height: 100), LayoutRect(x: 0, y: 0, width: .nan, height: 10),
                  LayoutRect(x: 0, y: 0, width: 100, height: 3)] {
            let l = DiskMapLayout.strata(tree: t, focus: t.rootNodeID, viewport: r)
            XCTAssertTrue(l.elements.isEmpty, "\(r)")
            XCTAssertNil(l.element(at: LayoutPoint(x: 1, y: 1)))
        }
    }

    func testEmptyFocusAndSingleChild() {
        let empty = MapFix.tree([])
        let l = DiskMapLayout.strata(tree: empty, focus: empty.rootNodeID, viewport: vp)
        XCTAssertEqual(l.elements.count, 1)
        XCTAssertFalse(l.elements[0].hasHiddenChildren)
        let zero = MapFix.tree([.file("z", bytes: 0)])
        let lz = DiskMapLayout.strata(tree: zero, focus: zero.rootNodeID, viewport: vp)
        XCTAssertEqual(lz.elements.count, 1)
        XCTAssertFalse(lz.elements[0].hasHiddenChildren)
        let single = MapFix.tree([.file("only", bytes: 500)])
        let ls = DiskMapLayout.strata(tree: single, focus: single.rootNodeID, viewport: vp)
        XCTAssertEqual(ls.elements.count, 2)
        XCTAssertEqual(ls.elements[1].rect.width, vp.width, accuracy: 1e-9)
        XCTAssertEqual(ls.elements[1].rect.x, vp.x, accuracy: 1e-9)
    }

    func testOwnBytesGapStaysAtRightEnd() {
        let t = MapFix.tree([.file("a", bytes: 750)], ownBytes: 250)
        let l = DiskMapLayout.strata(tree: t, focus: t.rootNodeID, viewport: vp)
        XCTAssertEqual(l.elements[1].rect.width, 750, accuracy: 1e-9)
        XCTAssertNil(l.element(at: LayoutPoint(x: vp.x + 900, y: vp.y + 70)))
    }

    func testCollapsedPackageAndSmallItems() {
        let pkg = SyntheticNode.dir("App.app", flags: [.package, .collapsed])
        var p = pkg; p.allocatedBytes = 5000
        let small = SyntheticNode(name: "3 small items", flags: [.smallItems], allocatedBytes: 3000, logicalBytes: 3000, modified: nil, children: [])
        let t = MapFix.tree([p, small])
        let l = DiskMapLayout.strata(tree: t, focus: t.rootNodeID, viewport: vp)
        let kids = t.children(of: t.rootNodeID)
        let pk = kids.first { t.node($0).flags.contains(.package) }!, sm = kids.first { t.node($0).flags.contains(.smallItems) }!
        XCTAssertTrue(l.element(for: pk)!.hasHiddenChildren)
        XCTAssertFalse(l.element(for: sm)!.hasHiddenChildren)
    }

    func testChildLargerThanParentIsClamped() {
        // A directory whose own recorded bytes are smaller than its child's can't happen from the indexer; force it.
        var kid = SyntheticNode.file("k", bytes: 100)
        kid.allocatedBytes = 100
        var parent = SyntheticNode.dir("p", [kid, .file("k2", bytes: 100)])
        parent.allocatedBytes = 0
        let t = MapFix.tree([parent])
        let l = DiskMapLayout.strata(tree: t, focus: t.rootNodeID, viewport: vp)
        MapFix.assertFinite(l)
        for e in l.elements { XCTAssertLessThanOrEqual(e.rect.maxX, vp.maxX + 1e-9) }
    }

    func testProtectedFlagFromTree() {
        let t = MapFix.tree([.dir("prot", flags: [.protected], [.file("x", bytes: 10)]), .file("y", bytes: 5)])
        let l = DiskMapLayout.strata(tree: t, focus: t.rootNodeID, viewport: vp)
        let names = t.children(of: t.rootNodeID).map { (t.node($0).name, l.element(for: $0)!.isProtected) }
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: names), ["prot": true, "y": false])
    }
}
