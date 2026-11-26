import XCTest
@testable import DiskKeeperCore

final class DiskTreeTests: XCTestCase {
    func testSyntheticTotalsAndOrder() {
        let t = DiskTree._synthetic(.dir("r", [
            .dir("small", [.file("a", bytes: 10)]),
            .dir("big", [.file("b", bytes: 500), .file("c", bytes: 100)]),
            .file("z", bytes: 5),
        ]), rootPath: "/s")
        XCTAssertEqual(t.nodeCount, 7)
        XCTAssertEqual(t.node(t.root).allocatedBytes, 615)
        XCTAssertEqual(t.node(t.root).fileCount, 4)
        let names = t.children(of: t.root).map { t.node($0).name }
        XCTAssertEqual(names, ["big", "small", "z"])
        let big = t.children(of: t.root).first!
        XCTAssertEqual(t.path(of: big), "/s/big")
        XCTAssertEqual(t.lookup(path: "/S/BIG"), big)
        XCTAssertEqual(t.ancestors(of: big), [t.root])
        XCTAssertEqual(t.node(big).parent, t.root)
    }

    func testRootSlashPath() {
        let t = DiskTree._synthetic(.dir("r", [.file("a", bytes: 1)]), rootPath: "/")
        let a = t.children(of: t.root).first!
        XCTAssertEqual(t.path(of: a), "/a")
        XCTAssertEqual(t.lookup(path: "/a"), a)
    }

    func testDisplayPathFullDiskMapping() {
        var t = DiskTree._synthetic(.dir("r", [.dir("Users", [.file("a", bytes: 1)])]), rootPath: "/System/Volumes/Data")
        t = DiskTree(rootPath: t.rootPath, physicalRootPath: t.physicalRootPath, scope: .fullDisk, createdAt: t.createdAt,
                     stats: t.stats, fileRecords: [], parents: t.parents, allocated: t.allocated, logical: t.logical,
                     mtimes: t.mtimes, fileCounts: t.fileCounts, flagBits: t.flagBits, nameStart: t.nameStart,
                     nameLen: t.nameLen, childStart: t.childStart, childIndex: t.childIndex, arena: t.arena,
                     firmlinks: FirmlinkMap.parse("/Users\tUsers"))
        let u = t.children(of: t.root).first!
        XCTAssertEqual(t.path(of: u), "/System/Volumes/Data/Users")
        XCTAssertEqual(t.displayPath(of: u), "/Users")
    }
}
