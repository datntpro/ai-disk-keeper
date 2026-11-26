import Darwin
import Foundation
import XCTest
@testable import DiskKeeperCore

final class DiskIndexerTests: XCTestCase {
    private var fx: FixtureHome!
    private var mounted: [String] = []

    override func setUpWithError() throws { fx = try FixtureHome() }
    override func tearDown() {
        for m in mounted { _ = Self.run("/usr/bin/hdiutil", ["detach", "-force", m]) }
        mounted = []
        fx = nil
        super.tearDown()
    }

    @discardableResult
    private static func run(_ exe: String, _ args: [String]) -> (status: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private let MiB = 1 << 20

    private func makeMixedFixture() throws {
        for i in 0..<40 { try fx.file("proj/src/s\(i).txt", bytes: 700 + i) }
        for i in 0..<3 { try fx.file("proj/big/b\(i).bin", bytes: 2 * MiB + i * 4096) }
        try fx.file("proj/h1.dat", bytes: 3 * MiB)
        try FileManager.default.createDirectory(atPath: fx.abs("proj/other"), withIntermediateDirectories: true)
        XCTAssertEqual(link(fx.abs("proj/h1.dat"), fx.abs("proj/other/h2.dat")), 0)
        try fx.symlink("proj/a/loop", to: "..")
        try fx.symlink("proj/b/out", to: "/")
        // sparse: 4 MiB logical, almost nothing allocated
        let sparse = fx.abs("proj/sparse.img")
        let fd = open(sparse, O_CREAT | O_WRONLY, 0o644)
        XCTAssertGreaterThanOrEqual(fd, 0)
        ftruncate(fd, Int64(4 * MiB))
        close(fd)
        // APFS clone
        let clone = fx.abs("proj/clone.bin")
        _ = clonefile(fx.abs("proj/big/b0.bin"), clone, 0)
    }

    // MARK: totals

    func testRootTotalsMatchFileSizer() async throws {
        try makeMixedFixture()
        let tree = try await IndexTest.index(fx)
        let report = try IndexTest.sizer(fx.home)
        let root = tree.node(tree.root)
        XCTAssertEqual(root.allocatedBytes, report.allocatedBytes)
        XCTAssertEqual(root.logicalBytes, report.logicalBytes)
        XCTAssertEqual(root.fileCount, report.fileCount)
        XCTAssertEqual(root.newestModification?.timeIntervalSince1970 ?? 0,
                       report.newestModification?.timeIntervalSince1970 ?? 1, accuracy: 0.001)
        XCTAssertEqual(tree.stats.directoryCount, report.directoryCount)
        XCTAssertEqual(tree.stats.symlinkCount, report.symlinkCount)
        XCTAssertEqual(tree.stats.hardlinkRepeatCount, report.hardlinkDuplicateCount)
        XCTAssertEqual(tree.stats.entriesVisited, report.entriesVisited)
        XCTAssertTrue(tree.stats.isComplete)
        XCTAssertNil(root.parent)
    }

    func testEveryDirectoryMatchesFileSizer() async throws {
        for d in 0..<5 {
            for f in 0..<7 { try fx.file("t/d\(d)/sub/f\(f).txt", bytes: 100 * (f + 1)) }
            try fx.file("t/d\(d)/big.bin", bytes: (d + 1) * MiB)
        }
        let tree = try await IndexTest.index(fx)
        var checked = 0
        for (_, n, p) in IndexTest.all(tree) where n.flags.contains(.directory) {
            let r = try IndexTest.sizer(p)
            XCTAssertEqual(n.allocatedBytes, r.allocatedBytes, p)
            XCTAssertEqual(n.logicalBytes, r.logicalBytes, p)
            XCTAssertEqual(n.fileCount, r.fileCount, p)
            checked += 1
        }
        XCTAssertGreaterThan(checked, 10)
    }

    func testHardlinkCountedOnce() async throws {
        try fx.file("a/one.bin", bytes: 2 * MiB)
        try FileManager.default.createDirectory(atPath: fx.abs("b"), withIntermediateDirectories: true)
        XCTAssertEqual(link(fx.abs("a/one.bin"), fx.abs("b/two.bin")), 0)
        let tree = try await IndexTest.index(fx)
        XCTAssertEqual(tree.stats.hardlinkRepeatCount, 1)
        let nodes = IndexTest.all(tree).map(\.1).filter { $0.flags.contains(.file) }
        XCTAssertEqual(nodes.count, 2)
        let repeats = nodes.filter { $0.flags.contains(.hardlinkRepeat) }
        XCTAssertEqual(repeats.count, 1)
        XCTAssertEqual(repeats[0].allocatedBytes, 0)
        XCTAssertEqual(tree.node(tree.root).fileCount, 1)
        XCTAssertEqual(tree.node(tree.root).allocatedBytes, try IndexTest.sizer(fx.home).allocatedBytes)
    }

    func testHardlinkRepeatHasRecord() async throws {
        try fx.file("a/one.bin", bytes: 2 * MiB)
        try FileManager.default.createDirectory(atPath: fx.abs("b"), withIntermediateDirectories: true)
        XCTAssertEqual(link(fx.abs("a/one.bin"), fx.abs("b/two.bin")), 0)
        let tree = try await IndexTest.index(fx)
        XCTAssertEqual(tree.fileRecords.count, 2)
        XCTAssertEqual(tree.fileRecords[0].inode, tree.fileRecords[1].inode)
        XCTAssertEqual(tree.fileRecords[0].device, tree.fileRecords[1].device)
        let rep = tree.fileRecords.filter { $0.flags.contains(.hardlinkRepeat) }
        XCTAssertEqual(rep.count, 1)
        XCTAssertEqual(rep[0].allocatedBytes, 0)
        XCTAssertEqual(tree.fileRecords[0].allocatedBytes > 0, true) // sorted desc: the counted one first
    }

    func testSymlinkLoopSafeAndNotFollowed() async throws {
        try fx.file("x/real.txt", bytes: 10)
        try fx.symlink("a/loop", to: "..")
        try fx.symlink("b/out", to: "/")
        let tree = try await IndexTest.index(fx)
        XCTAssertEqual(tree.stats.symlinkCount, 2)
        XCTAssertEqual(tree.node(tree.root).allocatedBytes, try IndexTest.sizer(fx.home).allocatedBytes)
        XCTAssertTrue(IndexTest.all(tree).allSatisfy { !$0.1.flags.contains(.symlink) })
    }

    func testSmallFilesFoldIntoOneAggregate() async throws {
        for i in 0..<50 { try fx.file("d/s\(i).txt", bytes: 1024) }
        try fx.file("d/b1.bin", bytes: 2 * MiB)
        try fx.file("d/b2.bin", bytes: 2 * MiB)
        let tree = try await IndexTest.index(fx)
        let d = try XCTUnwrap(tree.lookup(path: fx.abs("d")))
        let kids = tree.children(of: d).map(tree.node)
        XCTAssertEqual(kids.count, 3)
        XCTAssertEqual(kids.filter { $0.flags.contains(.file) }.count, 2)
        let small = try XCTUnwrap(kids.first { $0.flags.contains(.smallItems) })
        XCTAssertEqual(small.fileCount, 50)
        XCTAssertEqual(small.name, "50 small items")
        XCTAssertEqual(small.logicalBytes, 50 * 1024)
    }

    func testFileRecordsAndSizeBuckets() async throws {
        for i in 0..<3 { try fx.file("r/same\(i).bin", bytes: MiB) }
        try fx.file("r/two.bin", bytes: 2 * MiB)
        try fx.file("r/small.bin", bytes: 900 * 1024)
        let tree = try await IndexTest.index(fx)
        XCTAssertEqual(tree.fileRecords.count, 4)
        let buckets = tree.sizeBuckets(minimumLogicalBytes: Int64(MiB))
        XCTAssertEqual(buckets.count, 1)
        XCTAssertEqual(buckets[Int64(MiB)]?.count, 3)
        XCTAssertEqual(tree.fileRecords.first?.logicalBytes, Int64(2 * MiB))
    }

    // MARK: protected / packages / flags

    func testProtectedNodesAreFlaggedNotHidden() async throws {
        try fx.file(".ssh/id_rsa", bytes: 3 * MiB)
        try fx.file("Library/Keychains/login.keychain-db", bytes: 2 * MiB)
        try fx.file("Pictures/x.photoslibrary/database/db.sqlite", bytes: 2 * MiB)
        try fx.file("plain/ok.bin", bytes: 2 * MiB)
        let tree = try await IndexTest.index(fx)
        for rel in [".ssh", ".ssh/id_rsa", "Library/Keychains", "Library/Keychains/login.keychain-db", "Pictures/x.photoslibrary"] {
            let n = try XCTUnwrap(IndexTest.find(tree, fx.abs(rel)), rel)
            XCTAssertTrue(n.flags.contains(.protected), rel)
        }
        let plain = try XCTUnwrap(IndexTest.find(tree, fx.abs("plain/ok.bin")))
        XCTAssertFalse(plain.flags.contains(.protected))
        let report = try IndexTest.sizer(fx.home)
        XCTAssertEqual(tree.node(tree.root).allocatedBytes, report.allocatedBytes)
        XCTAssertFalse(tree.fileRecords.filter { $0.flags.contains(.protected) }.isEmpty)
    }

    func testPackageIsCollapsedButSizedExactly() async throws {
        try fx.file("Apps/Foo.app/Contents/MacOS/foo", bytes: 50_000)
        for i in 0..<200 { try fx.file("Apps/Foo.app/Contents/Resources/r\(i).txt", bytes: 300) }
        try fx.file("Apps/Foo.app/Contents/Big.bin", bytes: 2 * MiB)
        let tree = try await IndexTest.index(fx)
        let app = try XCTUnwrap(IndexTest.find(tree, fx.abs("Apps/Foo.app")))
        XCTAssertTrue(app.flags.isSuperset(of: [.package, .collapsed]))
        XCTAssertEqual(app.childCount, 0)
        let r = try IndexTest.sizer(fx.abs("Apps/Foo.app"))
        XCTAssertEqual(app.allocatedBytes, r.allocatedBytes)
        XCTAssertEqual(app.logicalBytes, r.logicalBytes)
        XCTAssertEqual(app.fileCount, r.fileCount)
        XCTAssertTrue(tree.fileRecords.isEmpty)
        XCTAssertEqual(tree.lookup(path: fx.abs("Apps/Foo.app/Contents/Big.bin")), app.id)
    }

    func testDatalessDirectoryNotDescended() async throws {
        try fx.file("cloud/inside/f.txt", bytes: 100)
        try fx.file("local/f.txt", bytes: 100)
        let target = fx.abs("cloud")
        var o = IndexOptions()
        o._datalessOverride = { $0 == target }
        let tree = try await IndexTest.index(fx, options: o)
        let cloud = try XCTUnwrap(IndexTest.find(tree, target))
        XCTAssertTrue(cloud.flags.contains(.dataless))
        XCTAssertEqual(cloud.childCount, 0)
        XCTAssertNil(IndexTest.find(tree, target + "/inside"))
        XCTAssertEqual(tree.stats.datalessCount, 1)
    }

    func testUnreadableDirectoryCountedOnce() async throws {
        try XCTSkipIf(getuid() == 0, "permission tests are meaningless as root")
        try fx.file("locked/f.txt", bytes: 100)
        try fx.file("ok/f.txt", bytes: 100)
        let locked = fx.abs("locked")
        XCTAssertEqual(chmod(locked, 0), 0)
        defer { _ = chmod(locked, 0o755) }
        let tree = try await IndexTest.index(fx)
        let report = try IndexTest.sizer(fx.home)
        XCTAssertEqual(tree.stats.directoryCount, report.directoryCount)
        XCTAssertEqual(tree.stats.issueCount, report.issueCount)
        XCTAssertEqual(tree.node(tree.root).allocatedBytes, report.allocatedBytes)
        let n = try XCTUnwrap(IndexTest.find(tree, locked))
        XCTAssertTrue(n.flags.contains(.unreadable))
        XCTAssertFalse(tree.stats.isComplete)
    }

    func testOtherVolumeNotCrossed() async throws {
        let img = fx.tmp.path("v.dmg")
        let create = Self.run("/usr/bin/hdiutil", ["create", "-size", "4m", "-fs", "APFS", "-volname", "ADKT", "-ov", img])
        try XCTSkipIf(create.status != 0, "hdiutil create unavailable")
        try FileManager.default.createDirectory(atPath: fx.abs("mnt"), withIntermediateDirectories: true)
        let mp = fx.abs("mnt/vol")
        try FileManager.default.createDirectory(atPath: mp, withIntermediateDirectories: true)
        let attach = Self.run("/usr/bin/hdiutil", ["attach", img + ".dmg", "-mountpoint", mp, "-nobrowse"])
        let attach2 = attach.status == 0 ? attach : Self.run("/usr/bin/hdiutil", ["attach", img, "-mountpoint", mp, "-nobrowse"])
        try XCTSkipIf(attach2.status != 0, "hdiutil attach unavailable")
        mounted.append(mp)
        FileManager.default.createFile(atPath: mp + "/inside.bin", contents: Data(count: 100_000))
        let tree = try await IndexTest.index(fx)
        let n = try XCTUnwrap(IndexTest.find(tree, mp))
        XCTAssertTrue(n.flags.contains(.otherVolume))
        XCTAssertEqual(n.allocatedBytes, 0)
        XCTAssertTrue(tree.stats.skippedMountPoints.contains(mp))
    }

    // MARK: determinism, lookup, names

    func testChildrenOrderDeterministic() async throws {
        for i in 0..<6 { try fx.file("o/dir\(i)/f.bin", bytes: 2 * MiB) }
        for n in ["b", "B", "a", "ä"] { try fx.file("o/z-\(n).txt", bytes: 0) }
        let t1 = try await IndexTest.index(fx), t2 = try await IndexTest.index(fx)
        func order(_ t: DiskTree) -> [String] {
            IndexTest.all(t).flatMap { (id, _, _) in t.children(of: id).map { t.path(of: $0) } }
        }
        XCTAssertEqual(order(t1), order(t2))
        // allocated desc: every child list is non-increasing
        for (id, _, _) in IndexTest.all(t1) {
            let sizes = t1.children(of: id).map { t1.node($0).allocatedBytes }
            XCTAssertEqual(sizes, sizes.sorted(by: >))
        }
    }

    func testPathAndLookupRoundTrip() async throws {
        try fx.file("Docs/Café/report.bin", bytes: 2 * MiB)
        try fx.file("Docs/Apps/X.app/Contents/x", bytes: 10)
        let tree = try await IndexTest.index(fx)
        for (id, n, p) in IndexTest.all(tree) where !n.flags.contains(.smallItems) {
            XCTAssertEqual(tree.lookup(path: p), id, p)
        }
        let upper = fx.abs("Docs/CAFÉ/REPORT.BIN")
        let nfd = fx.abs("Docs/Cafe\u{301}/report.bin")
        let target = try XCTUnwrap(tree.lookup(path: fx.abs("Docs/Café/report.bin")))
        XCTAssertEqual(tree.lookup(path: upper), target)
        XCTAssertEqual(tree.lookup(path: nfd), target)
        let pkg = try XCTUnwrap(tree.lookup(path: fx.abs("Docs/Apps/X.app")))
        XCTAssertEqual(tree.lookup(path: fx.abs("Docs/Apps/X.app/Contents/x")), pkg)
        XCTAssertNil(tree.lookup(path: "/definitely/not/under"))
        XCTAssertEqual(tree.ancestors(of: target).first, tree.root)
        XCTAssertEqual(tree.ancestors(of: tree.root), [])
    }

    func testUnicodeNames() async throws {
        let long = String(repeating: "x", count: 250) + ".bin"   // 254 bytes
        let names = ["Cafe\u{301}.bin", "😀🎉.bin", long, "new\nline.bin"]
        for n in names { try fx.file("u/" + n, bytes: 2 * MiB) }
        let tree = try await IndexTest.index(fx)
        let u = try XCTUnwrap(tree.lookup(path: fx.abs("u")))
        let got = Set(tree.children(of: u).map { tree.node($0).name })
        for n in names { XCTAssertTrue(got.contains(n), n) }
    }

    func testNonUTF8NameFlagged() async throws {
        let dir = fx.abs("raw")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        var bytes = Array((dir + "/bad").utf8CString.dropLast()).map { UInt8(bitPattern: $0) }
        bytes += [0xFF, 0xFE]
        let fd = bytes.withUnsafeBufferPointer { buf in
            buf.baseAddress!.withMemoryRebound(to: CChar.self, capacity: buf.count) { _ = $0; return -1 }
        }
        _ = fd
        var cpath = bytes.map { CChar(bitPattern: $0) }
        cpath.append(0)
        let f = open(cpath, O_CREAT | O_WRONLY, 0o644)
        try XCTSkipIf(f < 0, "filesystem rejects non-UTF8 names")
        ftruncate(f, Int64(2 * MiB)); close(f)
        let tree = try await IndexTest.index(fx)
        let n = IndexTest.all(tree).map(\.1).first { $0.flags.contains(.nonUTF8Name) }
        XCTAssertNotNil(n)
    }

    // MARK: budget / memory / state

    func testNodeBudgetFolds() async throws {
        for d in 0..<500 { try fx.file("many/d\(d)/sub/f.txt", bytes: 100) }
        var o = IndexOptions(); o.maxNodes = 50
        let tree = try await IndexTest.index(fx, options: o)
        XCTAssertLessThanOrEqual(tree.nodeCount, 50)
        XCTAssertTrue(tree.stats.nodeBudgetHit)
        XCTAssertFalse(tree.stats.isComplete)
        let r = try IndexTest.sizer(fx.home)
        let root = tree.node(tree.root)
        XCTAssertEqual(root.allocatedBytes, r.allocatedBytes)
        XCTAssertEqual(root.logicalBytes, r.logicalBytes)
        XCTAssertEqual(root.fileCount, r.fileCount)
    }

    func testMemoryPerNode() {
        var kids: [SyntheticNode] = []
        for i in 0..<4000 {
            kids.append(.dir("d\(i)", [.file("a", bytes: 10), .file("b", bytes: 20), .file("c", bytes: 30), .file("d", bytes: 40)]))
        }
        let t = DiskTree._synthetic(.dir("root", kids), rootPath: "/synthetic")
        XCTAssertEqual(t.nodeCount, 1 + 4000 * 5)
        XCTAssertLessThanOrEqual(t.estimatedMemoryBytes, 64 * t.nodeCount + t.arenaBytes + 4096)
        XCTAssertEqual(t.node(t.root).allocatedBytes, 4000 * 100)
        XCTAssertEqual(t.node(t.root).fileCount, 16000)
    }

    func testAlreadyRunning() async throws {
        for i in 0..<5 { try fx.file("f\(i).txt", bytes: 10) }
        let gate = DispatchSemaphore(value: 0)
        let entered = Signal()
        var o = IndexOptions()
        let once = OnceFlag()
        o._entryHook = { if once.first() { entered.signal(); gate.wait() } }
        let indexer = try IndexTest.indexer(fx, options: o)
        let first = Task { try await indexer.index(.home) }
        try await entered.wait()
        let running = await indexer.isRunning
        XCTAssertTrue(running)
        do {
            _ = try await indexer.index(.home)
            XCTFail("expected alreadyRunning")
        } catch let e as DiskIndexerError { XCTAssertEqual(e, .alreadyRunning) }
        gate.signal()
        let tree = try await first.value
        XCTAssertGreaterThan(tree.nodeCount, 0)
        let after = await indexer.isRunning
        XCTAssertFalse(after)
        let last = await indexer.lastTree
        XCTAssertNotNil(last)
    }

    func testProgressMonotonic() async throws {
        for d in 0..<30 { for f in 0..<100 { try fx.file("p/d\(d)/f\(f).txt", bytes: 10) } }
        var o = IndexOptions(); o.progressInterval = .zero
        let log = ProgressLog()
        _ = try await IndexTest.indexer(fx, options: o).index(.home) { log.add($0) }
        let all = log.items
        XCTAssertFalse(all.isEmpty)
        for (a, b) in zip(all, all.dropFirst()) {
            XCTAssertLessThanOrEqual(a.entriesVisited, b.entriesVisited)
            XCTAssertLessThanOrEqual(a.allocatedBytesSoFar, b.allocatedBytesSoFar)
        }
    }

    func testScopeToRootMapping() throws {
        let env = fx.env
        XCTAssertEqual(try DiskIndexer.root(for: .home, environment: env), fx.home)
        XCTAssertEqual(try DiskIndexer.root(for: .fullDisk, environment: env), "/System/Volumes/Data")
        XCTAssertEqual(try DiskIndexer.root(for: .folder("/a/b/"), environment: env), "/a/b")
        for bad in ["rel", "/a/../b", ""] {
            XCTAssertThrowsError(try DiskIndexer.root(for: .folder(bad), environment: env)) {
                XCTAssertEqual($0 as? DiskIndexerError, .rootNotFound(bad))
            }
        }
    }

    func testMissingRootThrows() async throws {
        let ix = try IndexTest.indexer(fx)
        do { _ = try await ix.index(.folder(fx.abs("nope"))); XCTFail() } catch let e as DiskIndexerError {
            XCTAssertEqual(e, .rootNotFound(fx.abs("nope")))
        }
    }

    func testFolderScopeSyntheticRoundTrip() async throws {
        try fx.file("sub/f.bin", bytes: 2 * MiB)
        let tree = try await IndexTest.indexer(fx).index(.folder(fx.abs("sub")))
        XCTAssertEqual(tree.rootPath, fx.abs("sub"))
        XCTAssertEqual(tree.scope, .folder(fx.abs("sub")))
        XCTAssertEqual(tree.displayPath(of: tree.root), fx.abs("sub"))
    }
}

final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func first() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
}

final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _items: [IndexProgress] = []
    func add(_ p: IndexProgress) { lock.lock(); _items.append(p); lock.unlock() }
    var items: [IndexProgress] { lock.lock(); defer { lock.unlock() }; return _items }
}
