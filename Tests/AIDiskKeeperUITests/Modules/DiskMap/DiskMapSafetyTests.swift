import Foundation
import XCTest
@testable import AIDiskKeeperUI

/// Invariant 12: the map is a viewer. No cleanup type, selection or removal API may appear under Modules/DiskMap.
final class DiskMapSafetyTests: XCTestCase {
    private var sourceDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/AIDiskKeeperUI/Modules/DiskMap")
    }

    func testNoCleanupOrRemovalAPIInDiskMapSources() throws {
        let pattern = try NSRegularExpression(
            pattern: #"CleanupEngine|CleanupFlowModel|CleanupCoordinator|SelectionModel|SelectionCheckbox|trashItem|removeItem|unlink|\.cleanup\b"#)
        let files = try FileManager.default.contentsOfDirectory(at: sourceDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 10, "the sources were not found at \(sourceDir.path)")
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            let range = NSRange(text.startIndex..., in: text)
            XCTAssertNil(pattern.firstMatch(in: text, range: range), "\(file.lastPathComponent) mentions cleanup or removal")
        }
    }

    @MainActor
    func testModelStoresNoCleanupType() async {
        let (index, _) = await DiskMapHarness.index(with: DiskMapFixtures.tree())
        let model = DiskMapModel(index: index, scanItems: { [] })
        for child in Mirror(reflecting: model).children {
            XCTAssertFalse(String(describing: type(of: child.value)).contains("Cleanup"), "\(child.label ?? "?")")
        }
        XCTAssertFalse(String(describing: type(of: index)).contains("Cleanup"))
    }
}
