import Foundation
import XCTest
@testable import DiskKeeperCore

struct SplitMix64: RandomNumberGenerator {
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

enum MapFix {
    static let root = "/synthetic"

    static func tree(_ children: [SyntheticNode], ownBytes: Int64 = 0) -> DiskTree {
        var r = SyntheticNode.dir("r", children)
        r.allocatedBytes = ownBytes
        return DiskTree._synthetic(r, rootPath: root)
    }

    /// Random tree: depth ≤ `depth`, fan-out ≤ `fan`, sizes log-uniform.
    static func random(seed: UInt64, depth: Int, fan: Int) -> DiskTree {
        var g = SplitMix64(seed: seed)
        func gen(_ d: Int, _ name: String) -> SyntheticNode {
            if d == 0 { return .file(name, bytes: Int64(1 << Int.random(in: 4...24, using: &g))) }
            let n = Int.random(in: 1...fan, using: &g)
            var kids = (0..<n).map { gen(d - 1, "n\($0)") }
            if Bool.random(using: &g) { kids.append(.file("f", bytes: Int64.random(in: 1...5000, using: &g))) }
            var s = SyntheticNode.dir(name, kids)
            s.allocatedBytes = Int64.random(in: 0...4096, using: &g)
            return s
        }
        return DiskTree._synthetic(gen(depth, "r"), rootPath: root)
    }

    static func children(_ l: DiskMapLayout, of node: DiskNodeID, _ tree: DiskTree) -> [MapElement] {
        tree.children(of: node).compactMap { l.element(for: $0) }
    }

    static func assertFinite(_ l: DiskMapLayout, file: StaticString = #filePath, line: UInt = #line) {
        for e in l.elements {
            XCTAssertTrue(e.rect.isFinite && e.rect.width >= 0 && e.rect.height >= 0, "\(e)", file: file, line: line)
        }
    }

    static func intersectionArea(_ a: LayoutRect, _ b: LayoutRect) -> Double {
        let w = min(a.maxX, b.maxX) - max(a.x, b.x), h = min(a.maxY, b.maxY) - max(a.y, b.y)
        return w > 0 && h > 0 ? w * h : 0
    }
}
