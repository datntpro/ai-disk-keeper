import Foundation
import XCTest
@testable import DiskKeeperCore

final class InUseIndexTests: XCTestCase {
    private func hold(_ name: String = "tail", pid: pid_t = 100, uid: uid_t = 501, cwd: String? = nil,
                      open: [String] = []) -> ProcessHold {
        ProcessHold(pid: pid, name: name, uid: uid, cwd: cwd, openPaths: open)
    }

    func testEqualAndInside() {
        let idx = InUseIndex([hold(open: ["/Users/u/proj/logs/a.log"])], currentUID: 501)
        XCTAssertEqual(idx.holder(of: "/Users/u/proj/logs/a.log")?.name, "tail")   // equal
        XCTAssertEqual(idx.holder(of: "/Users/u/proj/logs")?.pid, 100)              // open file is inside the item
        XCTAssertEqual(idx.holder(of: "/Users/u/proj")?.pid, 100)
    }

    func testParentOfHeldPathIsNotHeldBelow() {
        let idx = InUseIndex([hold(open: ["/Users/u/proj"])], currentUID: 501)
        XCTAssertNil(idx.holder(of: "/Users/u/proj/logs"), "an open parent does not hold its children")
    }

    func testSiblingPrefixIsNotAMatch() {
        let idx = InUseIndex([hold(open: ["/a/bc/file"])], currentUID: 501)
        XCTAssertNil(idx.holder(of: "/a/b"))
        XCTAssertNotNil(idx.holder(of: "/a/bc"))
    }

    func testCaseFoldAndAliases() {
        let idx = InUseIndex([hold(open: ["/Users/U/Proj/Log.TXT"])], currentUID: 501)
        XCTAssertNotNil(idx.holder(of: "/users/u/proj/log.txt"))
        let tmp = InUseIndex([hold(open: ["/private/tmp/x/f"])], currentUID: 501)
        XCTAssertNotNil(tmp.holder(of: "/tmp/x"), "/tmp is /private/tmp")
    }

    func testCwdCounts() {
        let idx = InUseIndex([hold("node", cwd: "/Users/u/proj/node_modules/.cache")], currentUID: 501)
        XCTAssertEqual(idx.holder(of: "/Users/u/proj/node_modules")?.name, "node")
    }

    func testOtherUserIgnored() {
        let idx = InUseIndex([hold(uid: 0, open: ["/Users/u/a"])], currentUID: 501)
        XCTAssertNil(idx.holder(of: "/Users/u/a"))
    }

    func testSymlinkSpellingOfTheItemIsResolved() throws {
        let dir = try TemporaryDirectory()
        let real = try dir.dir("real/inner").path
        let link = dir.path("link")
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: dir.path("real"))
        let realResolved = String(cString: realpath(real, nil)!)
        let idx = InUseIndex([hold(open: [realResolved])], currentUID: 501)
        XCTAssertNotNil(idx.holder(of: link + "/inner"), "item spelled through a symlink")
    }

    func testEmptySnapshotHoldsNothing() {
        XCTAssertNil(InUseIndex([], currentUID: 501).holder(of: "/"))
    }
}
