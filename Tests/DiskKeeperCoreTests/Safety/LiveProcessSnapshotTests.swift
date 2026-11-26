import XCTest
@testable import DiskKeeperCore

final class LiveProcessSnapshotTests: XCTestCase {
    private typealias E = LiveProcessScanner.ProcessEntry
    private let snap = [
        E(pid: 10, path: "/h/applications/x.app/contents/macos/x", uid: 501),
        E(pid: 11, path: "/h/applications/x.app2/contents/macos/x", uid: 501),
        E(pid: 12, path: "/h/applications/x.app/contents/xpcservices/h.xpc/h", uid: nil),
        E(pid: 13, path: "/usr/bin/true", uid: 0),
    ]

    func testEntriesMatchByPrefixCaseFoldedAndNotSiblings() {
        XCTAssertEqual(LiveProcessScanner.entries(insideBundleAt: "/H/Applications/X.app", in: snap).map(\.pid), [10, 12])
        XCTAssertTrue(LiveProcessScanner.entries(insideBundleAt: "/h/applications/y.app", in: snap).isEmpty)
    }

    func testSnapshotSeesThisTestProcessWithItsOwner() throws {
        let all = try XCTUnwrap(LiveProcessScanner.snapshot())
        let me = try XCTUnwrap(all.first { $0.pid == getpid() })
        XCTAssertEqual(me.uid, getuid())
        let root = (me.path as NSString).deletingLastPathComponent
        XCTAssertEqual(LiveProcessScanner.isAnyProcessRunning(insideBundleAt: root), true)
        XCTAssertEqual(LiveProcessScanner.isAnyProcessRunning(insideBundleAt: "/nonexistent/adk-none.app"), false)
    }

    private typealias U = LiveProcessScanner.UnresolvedProcess
    func testUnresolvedMatchesOnCommOwnedByCurrentUser() {
        let list = [U(pid: 1, uid: 501, comm: "myapp"), U(pid: 2, uid: 501, comm: "other"),
                    U(pid: 3, uid: 0, comm: "myapp"), U(pid: 4, uid: nil, comm: "myapp")]
        func m(_ exe: String?, conservative: Bool = false) -> [pid_t] {
            LiveProcessScanner.unresolvedMatches(executableName: exe, currentUID: 501, in: list, conservative: conservative).map(\.pid)
        }
        XCTAssertEqual(m("MyApp"), [1])
        XCTAssertEqual(m("Nope"), [])
        XCTAssertEqual(m(nil), [])
        XCTAssertEqual(m("Nope", conservative: true), [1, 2])
    }

    func testComPrefixedToMAXCOMLEN() {
        let list = [U(pid: 1, uid: 501, comm: "averylongexecutab")] // kernel truncates to 16 chars
        let name = "AVeryLongExecutableName"
        XCTAssertEqual(LiveProcessScanner.unresolvedMatches(executableName: name, currentUID: 501,
                                                            in: [U(pid: 1, uid: 501, comm: "averylongexecuta")]).count, 1)
        XCTAssertEqual(LiveProcessScanner.unresolvedMatches(executableName: name, currentUID: 501, in: list).count, 0)
    }

    func testBundleExecutableNameReadFromInfoPlist() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("adk-f2-\(UUID().uuidString)/X.app/Contents")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent().deletingLastPathComponent()) }
        try ("<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>CFBundleExecutable</key><string>Xexe</string></dict></plist>")
            .write(to: dir.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)
        XCTAssertEqual(LiveProcessScanner.bundleExecutableName(at: dir.deletingLastPathComponent().path), "Xexe")
        XCTAssertNil(LiveProcessScanner.bundleExecutableName(at: "/nonexistent/none.app"))
    }
}
