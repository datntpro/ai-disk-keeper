import DiskKeeperCore
import SwiftUI
import XCTest
@testable import DiskKeeperCore
@testable import AIDiskKeeperUI

/// 60 fps budget on a big tree. Bounds are for release builds; debug builds get ×50 (unoptimized code on shared
/// CI is far slower, so there it is only a sanity check). The numbers are printed for the PR.
@MainActor
final class DiskMapPerfTests: XCTestCase {
    #if DEBUG
    static let slack = 50.0
    #else
    static let slack = 1.0
    #endif

    /// Fan-out 9, depth 5: about 66 000 nodes (never touches the disk).
    static let tree: DiskTree = {
        var g = SplitMix64(seed: 7)
        func gen(_ d: Int, _ name: String) -> SyntheticNode {
            if d == 0 { return .file(name, bytes: Int64.random(in: 1...1_000_000, using: &g)) }
            return .dir(name, (0..<9).map { gen(d - 1, "n\($0)") })
        }
        return DiskTree._synthetic(gen(5, "r"), rootPath: "/synthetic")
    }()

    private func median(_ f: () -> Void) -> Double {
        var ts: [Double] = []
        for _ in 0..<10 {
            let s = DispatchTime.now().uptimeNanoseconds
            f()
            ts.append(Double(DispatchTime.now().uptimeNanoseconds - s) / 1e6)
        }
        return ts.sorted()[5]
    }

    private func report(_ name: String, _ ms: Double, bound: Double) {
        print("PERF \(name): \(String(format: "%.3f", ms)) ms (release bound \(bound) ms, ×\(Self.slack) here)")
        XCTAssertLessThan(ms, bound * Self.slack, name)
    }

    func testNodeCount() { XCTAssertGreaterThan(Self.tree.nodeCount, 50_000) }

    func testHoverHitTestOf10kPoints() {
        let layout = DiskMapLayout.strata(tree: Self.tree, focus: Self.tree.rootNodeID,
                                          viewport: LayoutRect(x: 0, y: 0, width: 1400, height: 600),
                                          options: DiskMapLayoutWorker.strataOptions)
        var g = SplitMix64(seed: 3)
        let points = (0..<10_000).map { _ in
            LayoutPoint(x: Double.random(in: 0..<1400, using: &g), y: Double.random(in: 0..<600, using: &g))
        }
        var hits = 0
        let ms = median { hits = 0; for p in points where layout.element(at: p) != nil { hits += 1 } }
        XCTAssertGreaterThan(hits, 5_000)
        report("hover hit-test ×10 000", ms, bound: 20)
    }

    func testLayoutRoundTripThroughTheModel() async {
        let m = await DiskMapHarness.model(tree: Self.tree, size: CGSize(width: 1400, height: 600))
        var ts: [Double] = []
        for i in 0..<10 {
            let s = DispatchTime.now().uptimeNanoseconds
            m.setMode(i % 2 == 0 ? .tiles : .strata)
            await m.waitForLayout()
            ts.append(Double(DispatchTime.now().uptimeNanoseconds - s) / 1e6)
        }
        report("layout round trip (median)", ts.sorted()[5], bound: 8)
    }

    func testColoringAllElements() {
        let layout = DiskMapLayout.strata(tree: Self.tree, focus: Self.tree.rootNodeID,
                                          viewport: LayoutRect(x: 0, y: 0, width: 1400, height: 600),
                                          options: DiskMapLayoutWorker.strataOptions)
        let overlay = DiskMapOverlay.build(tree: Self.tree, items: [])
        var n = 0
        let ms = median { n = DiskMapColoring.paints(layout: layout, tree: Self.tree, overlay: overlay, colorBy: .category, now: Date()).count }
        print("PERF coloring elements: \(n)")
        report("coloring all elements", ms, bound: 2)
    }

    func testCanvasRendersOffscreenWithinBudget() async {
        let m = await DiskMapHarness.model(tree: Self.tree, size: CGSize(width: 1400, height: 600))
        let layout = try! XCTUnwrap(m.layout)
        let base = DiskMapCanvas(layout: layout, tree: Self.tree, paints: m.paints, matching: nil, mode: .strata,
                                 rootName: "Home folder", transition: nil)
            .frame(width: 1400, height: 600)
        var rendered = 0
        let baseMs = median {
            let r = ImageRenderer(content: base)
            if let img = r.cgImage { rendered = img.width }
        }
        XCTAssertGreaterThan(rendered, 0, "the canvas must render a non-empty image")
        report("base canvas ImageRenderer 1400×600", baseMs, bound: 12)

        m.hover(CGPoint(x: 400, y: 20))
        m.select(m.layout!.elements[1].kind.nodeID!)
        let highlight = DiskMapHighlight(model: m).frame(width: 1400, height: 600)
        let hiMs = median { _ = ImageRenderer(content: highlight).cgImage }
        report("highlight canvas ImageRenderer", hiMs, bound: 1)
    }

    func testTilesCanvasRenders() async {
        let m = await DiskMapHarness.model(tree: DiskMapFixtures.tree(), mode: .tiles)
        let view = DiskMapCanvas(layout: m.layout!, tree: m.tree!, paints: m.paints, matching: nil,
                                 mode: .tiles, rootName: "Home folder", transition: nil).frame(width: 800, height: 400)
        let r = ImageRenderer(content: view)
        XCTAssertNotNil(r.cgImage)
    }
}

private extension MapElementKind {
    var nodeID: DiskNodeID? { if case .node(let id) = self { id } else { nil } }
}

/// Deterministic generator (the Core test target has its own copy).
private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
