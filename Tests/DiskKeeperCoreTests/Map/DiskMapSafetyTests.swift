import XCTest
@testable import DiskKeeperCore

final class DiskMapSafetyTests: XCTestCase {
    func testMapSourcesDoNotReferenceCleanup() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let dir = root.appendingPathComponent("Sources/DiskKeeperCore/Map")
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".swift") }
        XCTAssertGreaterThanOrEqual(files.count, 6)
        let banned = ["CleanupEngine", "CleanupPlan", "TrashAdapter", "trashItem", "removeItem", "FileManager", "unlink", "rename(", "CleanupMethod"]
        for f in files {
            let text = try String(contentsOf: dir.appendingPathComponent(f), encoding: .utf8)
            for b in banned { XCTAssertFalse(text.contains(b), "\(f) mentions \(b)") }
            for ui in ["import SwiftUI", "import AppKit", "import CoreGraphics"] { XCTAssertFalse(text.contains(ui), "\(f) \(ui)") }
        }
    }

    func testOverlayHoldsIDsNotItems() {
        let a = NodeAttribution(dominantCategory: nil, dominantTool: nil, attributedBytes: 0, tiers: [], itemIDs: [], isExact: false)
        for child in Mirror(reflecting: a).children { XCTAssertFalse(type(of: child.value) is ScanItem.Type) }
        XCTAssertFalse(String(describing: type(of: Mirror(reflecting: a).children.first { $0.label == "itemIDs" }!.value)).contains("ScanItem"))
        let o = DiskMapOverlay.build(tree: MapFix.tree([]), items: [])
        for child in Mirror(reflecting: o).children { XCTAssertFalse(String(describing: type(of: child.value)).contains("ScanItem")) }
    }
}
