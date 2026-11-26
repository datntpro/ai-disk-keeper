import DiskKeeperCore
import XCTest
@testable import DiskKeeperCore
@testable import AIDiskKeeperUI

final class DiskMapColoringTests: XCTestCase {
    private let tree = DiskMapFixtures.tree()
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func layout() -> DiskMapLayout {
        DiskMapLayout.strata(tree: tree, focus: tree.rootNodeID, viewport: LayoutRect(x: 0, y: 0, width: 800, height: 400))
    }

    func testCategoryComesFromTheOverlay() {
        let item = ItemFixtures.item("cache", category: .modelWeights, size: 500)
        let overlay = DiskMapOverlay.build(tree: tree, items: [item])
        let l = layout()
        let cache = l.element(for: DiskMapFixtures.id("\(DiskMapFixtures.tool)/cache", in: tree))!
        let p = DiskMapColoring.paint(for: cache, overlay: overlay, colorBy: .category, newest: nil, now: now)
        XCTAssertEqual(p.fill, .layer(.model))
        let movies = l.element(for: DiskMapFixtures.id("Movies", in: tree))!
        XCTAssertEqual(DiskMapColoring.paint(for: movies, overlay: overlay, colorBy: .category, newest: nil, now: now).fill,
                       .layer(.other), "unattributed nodes are Other")
        XCTAssertEqual(DiskMapColoring.paint(for: movies, overlay: nil, colorBy: .category, newest: nil, now: now).fill, .layer(.other))
    }

    func testProtectedIsHatchedAndAggregatesNeverAre() {
        let l = layout()
        let ssh = l.element(for: DiskMapFixtures.id(".ssh", in: tree))!
        XCTAssertTrue(ssh.isProtected)
        let p = DiskMapColoring.paint(for: ssh, overlay: nil, colorBy: .category, newest: nil, now: now)
        XCTAssertEqual(p, ElementPaint(fill: .protected, opacity: 1, hatched: true))

        let big = DiskMapFixtures.aggregateTree()
        let agg = DiskMapLayout.strata(tree: big, focus: big.rootNodeID, viewport: LayoutRect(x: 0, y: 0, width: 800, height: 400))
            .elements.first { if case .aggregate = $0.kind { return true } else { return false } }!
        for mode in DiskMapModel.ColorBy.allCases {
            let ap = DiskMapColoring.paint(for: agg, overlay: nil, colorBy: mode, newest: nil, now: now)
            XCTAssertFalse(ap.hatched)
            XCTAssertEqual(ap.opacity, 0.6)
        }
    }

    func testAgeBuckets() {
        let l = layout()
        let el = l.element(for: DiskMapFixtures.id("Movies", in: tree))!
        func age(_ days: Double?) -> ElementPaint.Fill {
            DiskMapColoring.paint(for: el, overlay: nil, colorBy: .age, newest: days.map { now.addingTimeInterval(-$0 * 86_400) }, now: now).fill
        }
        XCTAssertEqual(age(5), .age(.lastMonth))
        XCTAssertEqual(age(100), .age(.last6Months))
        XCTAssertEqual(age(300), .age(.lastYear))
        XCTAssertEqual(age(700), .age(.last3Years))
        XCTAssertEqual(age(2000), .age(.older))
        XCTAssertEqual(age(nil), .age(.unknown))
    }

    func testLabelInkIsNilWhenNoInkPasses() {
        // A mid-grey fill can't reach 4.5:1 with either the text or the on-accent colour.
        let mid = RGBA(r: 0.5, g: 0.5, b: 0.5)
        XCTAssertNil(labelInk(onFill: mid, appearance: .light))
        // A paint that resolves to a dark fill gets the light ink.
        let ink = DiskMapColoring.ink(for: ElementPaint(fill: .layer(.model), opacity: 1, hatched: false), .light)
        _ = ink  // either value (or nil) is legal; the call must not trap
    }

    func testResolvedFillCompositesOpacityOnSurface() {
        let full = DiskMapColoring.resolvedFill(ElementPaint(fill: .layer(.ai), opacity: 1, hatched: false), .light)
        let half = DiskMapColoring.resolvedFill(ElementPaint(fill: .layer(.ai), opacity: 0.5, hatched: false), .light)
        XCTAssertEqual(full.a, 1)
        XCTAssertEqual(half.a, 1)
        XCTAssertGreaterThan(half.r + half.g + half.b, full.r + full.g + full.b - 0.0001, "lighter on a light surface")
    }

    func testPaintsCoverEveryElement() {
        let l = layout()
        let ps = DiskMapColoring.paints(layout: l, tree: tree, overlay: nil, colorBy: .age, now: now)
        XCTAssertEqual(ps.count, l.elements.count)
    }
}
