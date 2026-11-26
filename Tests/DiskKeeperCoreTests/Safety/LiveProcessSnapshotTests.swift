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
}
