import XCTest
@testable import DiskKeeperCore

final class AppSettingsTests: XCTestCase {
    private let env = PathEnvironment(home: "/Users/tester", temporaryDirectory: "/tmp")

    func testDefaultRootsAndAllToolsEnabled() {
        let s = AppSettings.defaults
        XCTAssertEqual(s.projectRoots, ["~", "~/orca/workspaces", "~/Developer", "~/code", "~/src", "~/projects"])
        XCTAssertTrue(s.disabledTools.isEmpty)
        XCTAssertTrue(s.isEnabled("anything-new"))
        XCTAssertFalse(s.hasCompletedOnboarding)
    }

    func testScanScopeExpandsTilde() {
        var s = AppSettings.defaults
        s.excludedPaths = ["~/secret", "/Volumes/X"]
        let scope = s.scanScope(environment: env)
        XCTAssertEqual(scope.excludedPaths, ["/Users/tester/secret", "/Volumes/X"])
        XCTAssertEqual(scope.projectRoots.first, "/Users/tester")
        XCTAssertTrue(scope.projectRoots.contains("/Users/tester/Developer"))
    }

    func testAddStoresTildeAndDedupesWithFolding() throws {
        var s = AppSettings.defaults
        try s.addExcludedPath(URL(fileURLWithPath: "/Users/tester/Foo/"), environment: env)
        try s.addExcludedPath(URL(fileURLWithPath: "/users/TESTER/foo"), environment: env)
        XCTAssertEqual(s.excludedPaths, ["~/Foo"])
    }

    func testChildOfExcludedIsNoOpAndParentAbsorbs() throws {
        var s = AppSettings.defaults
        try s.addExcludedPath(URL(fileURLWithPath: "/Users/tester/a"), environment: env)
        try s.addExcludedPath(URL(fileURLWithPath: "/Users/tester/a/b"), environment: env)
        XCTAssertEqual(s.excludedPaths, ["~/a"])
        try s.addExcludedPath(URL(fileURLWithPath: "/Users/tester"), environment: env)
        XCTAssertEqual(s.excludedPaths, ["~"])
    }

    func testExcludedMayBeOutsideHomeButProjectRootMayNot() throws {
        var s = AppSettings.defaults
        try s.addExcludedPath(URL(fileURLWithPath: "/Volumes/Backup"), environment: env)
        XCTAssertEqual(s.excludedPaths, ["/Volumes/Backup"])
        XCTAssertThrowsError(try s.addProjectRoot(URL(fileURLWithPath: "/opt/x"), environment: env)) {
            XCTAssertEqual($0 as? SettingsError, .outsideHome("/opt/x"))
        }
        XCTAssertThrowsError(try s.addProjectRoot(URL(fileURLWithPath: "/Users/testerx/y"), environment: env))
        try s.addProjectRoot(URL(fileURLWithPath: "/Users/tester/work"), environment: env)
        try s.addProjectRoot(URL(fileURLWithPath: "/Users/tester/work"), environment: env)
        XCTAssertEqual(s.projectRoots.filter { $0 == "~/work" }.count, 1)
    }

    func testRelativeRejected() {
        var s = AppSettings.defaults
        XCTAssertThrowsError(try s.addExcludedPath(URL(string: "rel")!, environment: env)) { _ in }
    }

    func testToolToggleAndReset() throws {
        var s = AppSettings.defaults
        s.setTool("cursor", enabled: false)
        XCTAssertFalse(s.isEnabled("cursor"))
        XCTAssertEqual(s.scanScope(environment: env).disabledTools, ["cursor"])
        s.setTool("cursor", enabled: true)
        XCTAssertTrue(s.disabledTools.isEmpty)
        try s.addExcludedPath(URL(fileURLWithPath: "/x"), environment: env)
        s.removeProjectRoot("~")
        s.resetScopeToDefaults()
        XCTAssertEqual(s.projectRoots, AppSettings.defaultProjectRoots)
        XCTAssertTrue(s.excludedPaths.isEmpty)
    }
}
