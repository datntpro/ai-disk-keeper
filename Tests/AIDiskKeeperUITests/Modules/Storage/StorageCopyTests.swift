import DiskKeeperCore
import Foundation
import XCTest
@testable import AIDiskKeeperUI

@MainActor
final class StorageCopyTests: XCTestCase {
    func testExplanationsRenderInOrderInEnglishAndVietnamese() {
        XCTAssertEqual(StorageExplainCard.order, [.whyNumbersDiffer, .systemData, .purgeable])
        for lang in [AppLanguage.en, .vi] {
            L10n.withLanguage(lang) {
                for e in StorageExplainCard.order + [.snapshots, .trashNeedsFullDiskAccess] {
                    XCTAssertFalse(e.uiText.isEmpty)
                    if lang == .vi { XCTAssertNotEqual(e.uiText, L10n.withLanguage(.en) { e.uiText }, "\(e) has no vi text") }
                }
            }
        }
    }

    func testNewKeysResolveInBothLanguages() throws {
        let vi = try String(contentsOf: Self.root.appendingPathComponent("scripts/l10n/T40.vi.py"), encoding: .utf8)
        let keys = vi.split(separator: "\n").compactMap { line -> String? in
            guard let r = line.range(of: #"^\s*"(storage\.[A-Za-z.]+)":"#, options: .regularExpression) else { return nil }
            return String(line[r]).trimmingCharacters(in: .whitespaces).components(separatedBy: "\"")[1]
        }
        XCTAssertGreaterThan(keys.count, 25)
        let catalog = try JSONSerialization.jsonObject(
            with: Data(contentsOf: Self.root.appendingPathComponent("Sources/AIDiskKeeperUI/Resources/Localizable.xcstrings"))) as? [String: Any]
        let strings = catalog?["strings"] as? [String: [String: Any]] ?? [:]
        for k in keys {
            let locs = strings[k]?["localizations"] as? [String: Any]
            XCTAssertNotNil(locs?["en"], "\(k) missing en")
            XCTAssertNotNil(locs?["vi"], "\(k) missing vi")
        }
    }

    /// The screen is report-only: no mutation APIs and no tmutil anywhere in the Storage module or its copy.
    func testStorageSourcesContainNoMutationOrTmutil() throws {
        let ui = Self.root.appendingPathComponent("Sources/AIDiskKeeperUI")
        var files = try FileManager.default.contentsOfDirectory(at: ui.appendingPathComponent("Modules/Storage"), includingPropertiesForKeys: nil)
        files.append(ui.appendingPathComponent("Shared/StorageCopy.swift"))
        XCTAssertGreaterThan(files.count, 6)
        let banned = ["tmutil", "deletelocalsnapshots", "thinlocalsnapshots", "emptyTrash", "removeItem", "trashItem", "CleanupCoordinator"]
        for f in files where f.pathExtension == "swift" {
            let text = try String(contentsOf: f, encoding: .utf8)
            for b in banned { XCTAssertFalse(text.contains(b), "\(f.lastPathComponent) mentions \(b)") }
        }
    }

    private static var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }
}
