import XCTest
@testable import DiskKeeperCore

final class CLIInstallerTests: XCTestCase {
    private var tmp: TemporaryDirectory!
    private var home: String { tmp.url.path + "/home" }
    private var binary: URL!
    override func setUpWithError() throws {
        tmp = try TemporaryDirectory()
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        let dir = tmp.url.appendingPathComponent("AI Disk Keeper.app/Contents/MacOS")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        binary = dir.appendingPathComponent("adk")
        try Data("#!/bin/sh\n".utf8).write(to: binary)
        chmod(binary.path, 0o755)
    }
    override func tearDown() { tmp = nil }

    private func installer(path: String = "") -> CLIInstaller { CLIInstaller(home: home, binary: binary, pathVariable: path) }

    func testNothingIsCreatedUntilInstall() {
        _ = installer().state
        XCTAssertFalse(FileManager.default.fileExists(atPath: home + "/.local"))
    }

    func testInstallCreatesSymlinkAndIsIdempotent() throws {
        let i = installer()
        try i.install()
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: i.linkPath), binary.path)
        XCTAssertEqual(i.state, .installed)
        try i.install()
        XCTAssertEqual(i.state, .installed)
    }

    func testForeignFileIsRefusedAndKept() throws {
        let i = installer()
        try FileManager.default.createDirectory(atPath: i.directory, withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: URL(fileURLWithPath: i.linkPath))
        XCTAssertEqual(i.state, .foreign)
        XCTAssertThrowsError(try i.install()) { XCTAssertEqual($0 as? CLIInstaller.InstallError, .occupied(i.linkPath)) }
        XCTAssertEqual(try i.remove(), false)
        XCTAssertEqual(try String(contentsOfFile: i.linkPath, encoding: .utf8), "mine")
    }

    func testForeignSymlinkIsNotRemoved() throws {
        let i = installer()
        try FileManager.default.createDirectory(atPath: i.directory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: i.linkPath, withDestinationPath: "/usr/bin/true")
        XCTAssertEqual(i.state, .foreign)
        XCTAssertEqual(try i.remove(), false)
        XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath: i.linkPath))
    }

    func testRemoveDeletesOnlyOurSymlinkAndKeepsTheBinary() throws {
        let i = installer()
        try i.install()
        XCTAssertEqual(try i.remove(), true)
        XCTAssertEqual(i.state, .notInstalled)
        XCTAssertTrue(FileManager.default.fileExists(atPath: binary.path))
    }

    func testAppMovedLeavesOurOldLinkReplaceable() throws {
        let i = installer()
        try FileManager.default.createDirectory(atPath: i.directory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: i.linkPath, withDestinationPath: "/Applications/AI Disk Keeper.app/Contents/MacOS/adk")
        XCTAssertEqual(i.state, .installed)
        try i.install()
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: i.linkPath), binary.path)
    }

    func testAnotherAppsAdkLinkIsForeign() throws {
        let i = installer()
        try FileManager.default.createDirectory(atPath: i.directory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: i.linkPath, withDestinationPath: "/Applications/Other.app/Contents/MacOS/adk")
        XCTAssertEqual(i.state, .foreign)
        XCTAssertEqual(try i.remove(), false)
    }

    func testMissingBinaryAndPathHint() {
        let missing = CLIInstaller(home: home, binary: URL(fileURLWithPath: "/nonexistent/adk"))
        XCTAssertThrowsError(try missing.install())
        XCTAssertFalse(installer(path: "/usr/bin:/bin").directoryInPath)
        XCTAssertTrue(installer(path: "/usr/bin:\(home)/.local/bin").directoryInPath)
    }
}
