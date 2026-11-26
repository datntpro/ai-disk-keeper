import DiskKeeperCore
import XCTest
@testable import AIDiskKeeperUI

@MainActor
final class SettingsModelTests: XCTestCase {
    private var dir: URL!
    private let env = PathEnvironment(home: "/Users/tester", temporaryDirectory: "/tmp")

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("SettingsModelTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: dir) }

    private func makeModel(fda: FullDiskAccessStatus = .notGranted) -> SettingsModel {
        SettingsModel(store: SettingsStore(fileURL: dir.appendingPathComponent("settings.json")), environment: env,
                      availableTools: [ToolChoice(id: "cursor", name: "Cursor"), ToolChoice(id: "codex", name: "Codex")],
                      probe: { fda })
    }

    func testChangesPersistAndReload() {
        let m = makeModel()
        m.addExcludedPath(URL(fileURLWithPath: "/Users/tester/secret"))
        m.addProjectRoot(URL(fileURLWithPath: "/Users/tester/work"))
        m.setTool("cursor", enabled: false)
        let reloaded = makeModel()
        XCTAssertEqual(reloaded.settings.excludedPaths, ["~/secret"])
        XCTAssertTrue(reloaded.settings.projectRoots.contains("~/work"))
        XCTAssertFalse(reloaded.isEnabled("cursor"))
        reloaded.removeExcludedPath("~/secret")
        XCTAssertTrue(makeModel().settings.excludedPaths.isEmpty)
    }

    func testInvalidProjectRootSetsErrorAndKeepsSettings() {
        let m = makeModel()
        let before = m.settings
        m.addProjectRoot(URL(fileURLWithPath: "/opt/elsewhere"))
        XCTAssertNotNil(m.lastError)
        XCTAssertEqual(m.settings, before)
    }

    func testScanScopeReflectsChangesIncludingProvider() {
        let m = makeModel()
        m.addExcludedPath(URL(fileURLWithPath: "/Users/tester/secret"))
        m.setTool("codex", enabled: false)
        XCTAssertEqual(m.scanScope.excludedPaths, ["/Users/tester/secret"])
        XCTAssertEqual(m.scanScope.disabledTools, ["codex"])
        XCTAssertEqual(m.scopeProvider.current, m.scanScope)
    }

    func testAllToolsDisabledWarning() {
        let m = makeModel()
        XCTAssertFalse(m.allToolsDisabled)
        m.setTool("cursor", enabled: false)
        m.setTool("codex", enabled: false)
        XCTAssertTrue(m.allToolsDisabled)
    }

    func testSaveFailureSurfacesError() throws {
        let file = dir.appendingPathComponent("blocker")
        try Data().write(to: file)   // a file where the parent directory should be
        let m = SettingsModel(store: SettingsStore(fileURL: file.appendingPathComponent("settings.json")),
                              environment: env, probe: { .unknown })
        m.setTool("cursor", enabled: false)
        XCTAssertNotNil(m.lastError)
    }

    func testFdaStatusRefresh() {
        XCTAssertEqual(makeModel(fda: .granted).fdaStatus, .granted)
        XCTAssertEqual(makeModel(fda: .notGranted).fdaStatus, .notGranted)
    }

    func testProjectRootsOutsideHomeInFileAreDroppedWithWarning() throws {
        let url = dir.appendingPathComponent("settings.json")
        try Data(#"{"schemaVersion":1,"projectRoots":["/","~/ok"]}"#.utf8).write(to: url)
        let m = makeModel()
        XCTAssertEqual(m.settings.projectRoots, ["~/ok"])
        XCTAssertNotNil(m.loadWarning)
    }
}
