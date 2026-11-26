import DiskKeeperCore
import XCTest
@testable import AIDiskKeeperUI

/// The menu bar has no cleanup path: not by name in its sources, and not as a stored dependency of its model.
final class MenuBarSafetyTests: XCTestCase {
    func testNoCleanupSymbolsInMenuBarSources() throws {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/AIDiskKeeperUI/MenuBar")
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThanOrEqual(files.count, 6)
        let banned = try NSRegularExpression(
            pattern: #"CleanupCoordinator|CleanupFlowModel|CleanupEngine|SelectionModel|review\(|trashItem|removeItem"#)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            let hit = banned.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
            XCTAssertNil(hit, "\(file.lastPathComponent) mentions a cleanup symbol")
        }
    }

    @MainActor func testModelHoldsNoCleanupType() {
        let care = CareRig()
        let name = "T47-safety-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        let model = MenuBarModel(storage: StorageModel(load: { StorageFix.overview() }), care: care.model, scan: care.scan,
                                 settings: SettingsModel(store: SettingsStore(fileURL: URL(fileURLWithPath: "/nonexistent/s.json")),
                                                         environment: .current(), probe: { .unknown }),
                                 notifier: SilentLowSpaceNotifier(), defaults: UserDefaults(suiteName: name)!)
        for child in Mirror(reflecting: model).children {
            let type = String(describing: Swift.type(of: child.value))
            XCTAssertFalse(type.contains("Cleanup"), "\(child.label ?? "?"): \(type)")
            XCTAssertFalse(type.contains("SelectionModel"), "\(child.label ?? "?"): \(type)")
        }
    }
}
