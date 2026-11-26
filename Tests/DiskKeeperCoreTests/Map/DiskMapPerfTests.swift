import XCTest
@testable import DiskKeeperCore

final class DiskMapPerfTests: XCTestCase {
    #if DEBUG
    static let slack = 25.0   // unoptimized builds are ~15× slower; the real bounds apply to release
    #else
    static let slack = 1.0
    #endif

    /// 300k-ish nodes: fan-out 20, depth 4 (20^4 = 160k leaves + 8.4k dirs…), sizes pseudo-random.
    static let tree: DiskTree = {
        var g = SplitMix64(seed: 99)
        func gen(_ d: Int, _ name: String) -> SyntheticNode {
            if d == 0 { return .file(name, bytes: Int64.random(in: 1...1_000_000, using: &g)) }
            return .dir(name, (0..<20).map { gen(d - 1, "n\($0)") })
        }
        var kids = (0..<20).map { gen(4, "t\($0)") }
        kids.append(contentsOf: (0..<12).map { gen(4, "u\($0)") })
        return DiskTree._synthetic(.dir("r", kids), rootPath: "/synthetic")
    }()

    func median(_ f: () -> Void) -> Double {
        var ts: [Double] = []
        for _ in 0..<10 {
            let s = DispatchTime.now().uptimeNanoseconds
            f()
            ts.append(Double(DispatchTime.now().uptimeNanoseconds - s) / 1e6)
        }
        return ts.sorted()[5]
    }

    func testStrataFast() {
        let t = Self.tree
        XCTAssertGreaterThan(t.nodeCount, 250_000)
        let vp = LayoutRect(x: 0, y: 0, width: 1600, height: 600)
        let ms = median { _ = DiskMapLayout.strata(tree: t, focus: t.rootNodeID, viewport: vp) }
        print("PERF strata \(ms) ms")
        XCTAssertLessThan(ms, 5 * Self.slack)
    }

    func testTilesFast() {
        let t = Self.tree
        let vp = LayoutRect(x: 0, y: 0, width: 1600, height: 600)
        let ms = median { _ = DiskMapLayout.tiles(tree: t, focus: t.rootNodeID, viewport: vp) }
        print("PERF tiles \(ms) ms")
        XCTAssertLessThan(ms, 10 * Self.slack)
    }

    func testOverlayBuildFast() {
        let t = Self.tree
        var g = SplitMix64(seed: 3)
        var items: [ScanItem] = []
        for i in 0..<5000 {
            let p = "/synthetic/t\(Int.random(in: 0..<20, using: &g))/n\(Int.random(in: 0..<20, using: &g))/n\(Int.random(in: 0..<20, using: &g))/n\(Int.random(in: 0..<20, using: &g))"
            items.append(DiskMapOverlayTests.item(p, bytes: 1000, id: "i\(i)"))
        }
        let ms = median { _ = DiskMapOverlay.build(tree: t, items: items) }
        print("PERF overlay \(ms) ms")
        XCTAssertLessThan(ms, 20 * Self.slack)
    }
}
