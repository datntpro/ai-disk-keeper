import XCTest
@testable import DiskKeeperCore

final class SettingsStoreTests: XCTestCase {
    private var tmp: TemporaryDirectory!
    private var store: SettingsStore!

    override func setUpWithError() throws {
        tmp = try TemporaryDirectory()
        store = SettingsStore(fileURL: tmp.url.appendingPathComponent("AIDiskKeeper/settings.json"))
    }

    func testMissingFileGivesDefaults() {
        let (s, w) = store.load()
        XCTAssertEqual(s, .defaults)
        XCTAssertNil(w)
    }

    func testRoundTripAndPermissions() throws {
        var s = AppSettings.defaults
        s.hasCompletedOnboarding = true
        s.excludedPaths = ["~/x"]
        s.disabledTools = ["cursor", "codex"]
        try store.save(s)
        XCTAssertEqual(store.load().0, s)
        let attrs = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)
        XCTAssertEqual(attrs[.posixPermissions] as? Int, 0o600)
        let dir = try FileManager.default.attributesOfItem(atPath: store.fileURL.deletingLastPathComponent().path)
        XCTAssertEqual(dir[.posixPermissions] as? Int, 0o700)
    }

    func testCorruptFileIsBackedUp() throws {
        try FileManager.default.createDirectory(at: store.fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: store.fileURL)
        let (s, w) = store.load()
        XCTAssertEqual(s, .defaults)
        XCTAssertNotNil(w)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
        let names = try FileManager.default.contentsOfDirectory(atPath: store.fileURL.deletingLastPathComponent().path)
        XCTAssertTrue(names.contains { $0.hasPrefix("settings.json.corrupt-") })
    }

    func testNewerSchemaIsTreatedAsCorrupt() throws {
        try FileManager.default.createDirectory(at: store.fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(#"{"schemaVersion":99}"#.utf8).write(to: store.fileURL)
        let (s, w) = store.load()
        XCTAssertEqual(s, .defaults)
        XCTAssertNotNil(w)
    }

    func testUnknownKeysIgnoredAndMissingKeysDefaulted() throws {
        try FileManager.default.createDirectory(at: store.fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(#"{"schemaVersion":1,"hasCompletedOnboarding":true,"future":[1,2]}"#.utf8).write(to: store.fileURL)
        let (s, w) = store.load()
        XCTAssertNil(w)
        XCTAssertTrue(s.hasCompletedOnboarding)
        XCTAssertEqual(s.projectRoots, AppSettings.defaultProjectRoots)
    }

    func testDefaultLocationIsNextToAuditLog() {
        let env = PathEnvironment(home: "/h", temporaryDirectory: "/tmp")
        XCTAssertEqual(SettingsStore.defaultFileURL(environment: env).path,
                       "/h/Library/Application Support/AIDiskKeeper/settings.json")
    }
}
