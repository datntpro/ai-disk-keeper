import DiskKeeperCore
import XCTest
@testable import AIDiskKeeperUI

@MainActor
final class LanguageSwitchTests: XCTestCase {
    private var dir: URL!
    private let env = PathEnvironment(home: "/Users/tester", temporaryDirectory: "/tmp")

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("LanguageSwitchTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDown() async throws {
        L10n.apply(.en)
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeModel() -> SettingsModel {
        SettingsModel(store: SettingsStore(fileURL: dir.appendingPathComponent("settings.json")), environment: env,
                      probe: { .unknown })
    }

    func testApplyChangesTierLabels() {
        L10n.apply(.vi)
        XCTAssertEqual(TierStyle.style(for: .safe).label, "An toàn")
        XCTAssertEqual(TierStyle.style(for: .review).label, "Cần xem")
        XCTAssertEqual(TierStyle.style(for: .keep).label, "Giữ lại")
        L10n.apply(.en)
        XCTAssertEqual(TierStyle.style(for: .safe).label, "Safe")
    }

    func testSetLanguagePersistsAndBumpsRevision() {
        let m = makeModel()
        XCTAssertEqual(m.language, .system)
        let before = m.languageRevision
        m.setLanguage(.vi)
        XCTAssertEqual(m.settings.language, "vi")
        XCTAssertEqual(m.languageRevision, before + 1)
        XCTAssertEqual(L10n.languageCode, "vi")
        XCTAssertEqual(makeModel().language, .vi)          // survives a relaunch
        m.setLanguage(.en)
        XCTAssertEqual(L10n.languageCode, "en")
    }

    func testUnknownStoredLanguageMeansSystem() {
        XCTAssertEqual(AppLanguage(storedValue: "klingon"), .system)
        XCTAssertEqual(AppLanguage(storedValue: "vi"), .vi)
    }

    func testAppleLanguagesIsWrittenForNextLaunch() throws {
        let suite = "LanguageSwitchTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        SettingsModel.persistAppleLanguages(.vi, defaults: defaults)
        XCTAssertEqual(defaults.persistentDomain(forName: suite)?["AppleLanguages"] as? [String], ["vi"])
        SettingsModel.persistAppleLanguages(.system, defaults: defaults)
        XCTAssertNil(defaults.persistentDomain(forName: suite)?["AppleLanguages"])
    }

    func testCorruptSettingsWarningFollowsLanguage() throws {
        let file = dir.appendingPathComponent("settings.json")
        try Data("not json".utf8).write(to: file)
        let m = makeModel()
        let w = try XCTUnwrap(m.loadWarning)
        L10n.apply(.en)
        XCTAssertTrue(w.uiMessage.contains("unreadable"))
        L10n.apply(.vi)
        XCTAssertTrue(w.uiMessage.contains("Không đọc được cài đặt"), w.uiMessage)
    }
}
