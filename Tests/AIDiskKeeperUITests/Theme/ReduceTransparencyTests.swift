import Foundation
import XCTest

final class ReduceTransparencyTests: XCTestCase {
    /// Bars and materials go through `.adkBarBackground()`; nothing else may use `.bar` / `Material`.
    func testNoRawMaterialOutsideModifier() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/AIDiskKeeperUI")
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" && $0.lastPathComponent != "ReduceTransparency.swift" }
        XCTAssertFalse(files.isEmpty)
        for f in files {
            let text = try String(contentsOf: f, encoding: .utf8)
            XCTAssertFalse(text.contains(".background(.bar)"), f.lastPathComponent)
            XCTAssertFalse(text.contains("Material"), f.lastPathComponent)
            XCTAssertFalse(text.contains("ultraThin") || text.contains(".regularMaterial"), f.lastPathComponent)
        }
    }
}
