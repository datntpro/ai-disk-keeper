import XCTest
@testable import DiskKeeperCore

final class FullDiskAccessProbeTests: XCTestCase {
    private var tmp: TemporaryDirectory!
    override func setUpWithError() throws { tmp = try TemporaryDirectory() }
    override func tearDown() { tmp = nil }   // deinit restores chmod'ed modes

    func testNoPathsIsUnknown() {
        XCTAssertEqual(FullDiskAccessProbe(probePaths: []).check(), .unknown)
        XCTAssertEqual(FullDiskAccessProbe(probePaths: [tmp.path("missing")]).check(), .unknown)
    }

    func testReadableDirAndFileAreGranted() throws {
        try tmp.dir("d")
        try tmp.file("f", bytes: 1)
        XCTAssertEqual(FullDiskAccessProbe(probePaths: [tmp.path("d")]).check(), .granted)
        XCTAssertEqual(FullDiskAccessProbe(probePaths: [tmp.path("f")]).check(), .granted)
    }

    func testUnreadableDirIsNotGranted() throws {
        try tmp.dir("locked")
        try tmp.chmod("locked", 0o000)
        if getuid() == 0 { throw XCTSkip("root bypasses permissions") }
        XCTAssertEqual(FullDiskAccessProbe(probePaths: [tmp.path("locked")]).check(), .notGranted)
    }

    func testStandardPathsLiveUnderLibrary() {
        let env = PathEnvironment(home: "/h", temporaryDirectory: "/tmp")
        XCTAssertTrue(FullDiskAccessProbe.standard(environment: env).probePaths.allSatisfy { $0.hasPrefix("/h/Library/") })
    }
}
