import Darwin
import Foundation
import XCTest
import os
@testable import DiskKeeperCore

final class FileSizerTests: XCTestCase {
    private var tmp: TemporaryDirectory!
    private var mountedPaths: [String] = []

    override func setUpWithError() throws {
        tmp = try TemporaryDirectory()
    }

    override func tearDown() {
        for m in mountedPaths { _ = Self.run("/usr/bin/hdiutil", ["detach", "-force", m]) }
        mountedPaths.removeAll()
        tmp.cleanup()
        super.tearDown()
    }

    private func kb(_ n: Int) -> Int { n * 1024 }

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

    private func size(_ url: URL, _ options: FileSizer.Options = .init()) throws -> SizeReport {
        try FileSizer(options: options).sizeBlocking(of: url)
    }

    private func skipIfRoot() throws {
        try XCTSkipIf(getuid() == 0, "permission tests are meaningless as root")
    }

    // MARK: Basic shapes

    func testEmptyDirectory() throws {
        let d = try tmp.dir("empty")
        let r = try size(d)
        XCTAssertEqual(r.directoryCount, 1)
        XCTAssertEqual(r.fileCount, 0)
        XCTAssertTrue(r.isComplete)
        let mtime = try FileManager.default.attributesOfItem(atPath: d.path)[.modificationDate] as? Date
        XCTAssertEqual(try XCTUnwrap(r.newestModification).timeIntervalSince1970,
                       try XCTUnwrap(mtime).timeIntervalSince1970, accuracy: 1)
    }

    func testRegularFileRoot() throws {
        let f = try tmp.file("f.bin", bytes: 10_000)
        let r = try size(f)
        XCTAssertEqual(r.rootKind, .file)
        XCTAssertEqual(r.logicalBytes, 10_000)
        XCTAssertGreaterThanOrEqual(r.allocatedBytes, 10_000)
        XCTAssertEqual(r.fileCount, 1)
    }

    func testNestedTreeCountsAndSizes() throws {
        try tmp.file("t/a/b/c/d.bin", bytes: 5000)
        try tmp.file("t/a/x.txt", bytes: 100)
        try tmp.file("t/a/b/y", bytes: 0)
        let r = try size(tmp.url.appendingPathComponent("t"))
        XCTAssertEqual(r.fileCount, 3)
        XCTAssertEqual(r.directoryCount, 4)
        XCTAssertEqual(r.logicalBytes, 5100)
    }

    func testMatchesDuWithinTolerance() throws {
        var rng = SystemRandomNumberGenerator()
        for i in 0..<300 {
            try tmp.file("t/d\(i % 10)/f\(i)", bytes: Int.random(in: 0...50_000, using: &rng))
        }
        try tmp.hardlink("t/d1/link", to: "t/d0/f0")
        let root = tmp.url.appendingPathComponent("t")
        let r = try size(root)
        let du = Self.run("/usr/bin/du", ["-sk", root.path])
        let duKB = try XCTUnwrap(Int(du.out.split(whereSeparator: { $0 == "\t" || $0 == " " }).first ?? ""))
        let ours = Int(r.allocatedBytes / 1024)
        XCTAssertLessThanOrEqual(abs(ours - duKB), max(16, duKB / 100), "ours=\(ours) du=\(duKB)")
    }

    // MARK: Symlinks

    func testSymlinkedDirectoryIsZeroBytesAndNotTraversed() throws {
        try tmp.file("outside/big.bin", bytes: 1_000_000)
        try tmp.dir("tree")
        try tmp.symlink("tree/link", to: "../outside")
        let r = try size(tmp.url.appendingPathComponent("tree"))
        XCTAssertEqual(r.symlinkCount, 1)
        XCTAssertEqual(r.fileCount, 0)
        XCTAssertLessThan(r.allocatedBytes, Int64(kb(64)))
    }

    func testSymlinkLoopTerminates() throws {
        try tmp.file("tree/a/f.bin", bytes: 3000)
        let root = tmp.url.appendingPathComponent("tree")
        let before = try size(root)
        try tmp.symlink("tree/a/loop", to: "..")
        try tmp.symlink("tree/a/self", to: ".")
        let after = try size(root)
        XCTAssertEqual(after.allocatedBytes, before.allocatedBytes)
        XCTAssertEqual(after.fileCount, before.fileCount)
        XCTAssertEqual(after.symlinkCount, 2)
    }

    func testRootSymlinkIsNotFollowed() throws {
        try tmp.file("target/big.bin", bytes: 1_000_000)
        try tmp.symlink("link", to: "target")
        let r = try size(URL(fileURLWithPath: tmp.path("link"), isDirectory: true))
        XCTAssertEqual(r.rootKind, .symlink)
        XCTAssertEqual(r.allocatedBytes, 0)
        XCTAssertEqual(r.fileCount, 0)
    }

    func testDanglingSymlinkIsNotAnIssue() throws {
        try tmp.dir("tree")
        try tmp.symlink("tree/dangling", to: "/nonexistent-diskkeeper-target")
        let r = try size(tmp.url.appendingPathComponent("tree"))
        XCTAssertEqual(r.symlinkCount, 1)
        XCTAssertTrue(r.isComplete)
    }

    // MARK: Hardlinks, clones, sparse

    func testHardlinksCountedOnce() throws {
        try tmp.file("tree/one.bin", bytes: 1_000_000)
        try tmp.hardlink("tree/sub/two.bin", to: "tree/one.bin")
        let r = try size(tmp.url.appendingPathComponent("tree"))
        XCTAssertEqual(r.fileCount, 1)
        XCTAssertEqual(r.hardlinkDuplicateCount, 1)
        XCTAssertEqual(r.logicalBytes, 1_000_000)
        XCTAssertLessThan(r.allocatedBytes, 1_100_000)
    }

    func testHardlinkToOutsideTreeCountedOnce() throws {
        try tmp.file("outside/one.bin", bytes: 1_000_000)
        try tmp.hardlink("tree/in.bin", to: "outside/one.bin")
        let r = try size(tmp.url.appendingPathComponent("tree"))
        XCTAssertEqual(r.fileCount, 1)
        XCTAssertEqual(r.hardlinkDuplicateCount, 0)
        XCTAssertEqual(r.logicalBytes, 1_000_000)
    }

    func testAPFSClonesAreCountedPerFile() throws {
        let src = try tmp.file("tree/a.bin", bytes: 1_048_576)
        let dst = tmp.url.appendingPathComponent("tree/b.bin")
        if clonefile(src.path, dst.path, 0) != 0 {
            let code = errno
            throw XCTSkip("clonefile unavailable (errno \(code))")
        }
        let r = try size(tmp.url.appendingPathComponent("tree"))
        XCTAssertGreaterThanOrEqual(r.allocatedBytes, 2 * 1_048_576)
    }

    func testSparseFileUsesAllocatedSize() throws {
        let f = try tmp.file("tree/sparse.bin")
        let h = try FileHandle(forWritingTo: f)
        try h.seek(toOffset: 100 * 1_048_576)
        try h.write(contentsOf: Data([1]))
        try h.close()
        let r = try size(f)
        XCTAssertEqual(r.logicalBytes, Int64(100 * 1_048_576 + 1))
        try XCTSkipIf(r.allocatedBytes >= r.logicalBytes, "filesystem is not sparse-capable")
        XCTAssertLessThan(r.allocatedBytes, 1_048_576)
    }

    // MARK: Permissions

    func testUnreadableDirectoryIsRecordedAndWalkContinues() throws {
        try skipIfRoot()
        try tmp.file("tree/locked/secret.bin", bytes: 1_000_000)
        try tmp.file("tree/ok.bin", bytes: 2000)
        try tmp.chmod("tree/locked", 0)
        let r = try size(tmp.url.appendingPathComponent("tree"))
        XCTAssertEqual(r.issueCount, 1)
        XCTAssertEqual(r.issues.first?.kind, .permissionDenied)
        XCTAssertEqual(r.issues.first?.path, tmp.path("tree/locked"))
        XCTAssertEqual(r.directoryCount, 2) // tree + locked, counted once
        XCTAssertEqual(r.entriesVisited, 3) // tree, locked, ok.bin (DNR repeat not recounted)
        XCTAssertFalse(r.isComplete)
        XCTAssertGreaterThanOrEqual(r.logicalBytes, 2000)
        XCTAssertLessThan(r.logicalBytes, 1_000_000)
    }

    func testUnreadableFileIsStillCounted() throws {
        try skipIfRoot()
        try tmp.file("tree/f.bin", bytes: 4000)
        try tmp.chmod("tree/f.bin", 0)
        let r = try size(tmp.url.appendingPathComponent("tree"))
        XCTAssertEqual(r.fileCount, 1)
        XCTAssertEqual(r.logicalBytes, 4000)
        XCTAssertTrue(r.isComplete)
    }

    func testIssuesAreCappedButCounted() throws {
        try skipIfRoot()
        for i in 0..<5 {
            try tmp.file("tree/l\(i)/x", bytes: 10)
            try tmp.chmod("tree/l\(i)", 0)
        }
        let r = try size(tmp.url.appendingPathComponent("tree"),
                         .init(maxRecordedIssues: 2))
        XCTAssertEqual(r.issues.count, 2)
        XCTAssertEqual(r.issueCount, 5)
    }

    func testErrnoKindMapping() {
        let table: [(Int32, SizingIssue.Kind)] = [
            (EACCES, .permissionDenied), (EPERM, .notPermitted),
            (ENOENT, .vanished), (ENOTDIR, .vanished),
            (ENAMETOOLONG, .nameTooLong),
            (EDEADLK, .dataless), (ENOTSUP, .dataless),
            (EIO, .ioError), (EINVAL, .other),
        ]
        for (code, kind) in table {
            XCTAssertEqual(SizingIssue.kind(forErrno: code), kind, "errno \(code)")
        }
    }

    // MARK: Volumes

    func testOtherVolumeIsNotCrossedByDefault() throws {
        try tmp.dir("tree/mnt")
        let img = tmp.path("img.dmg")
        let mountPoint = tmp.path("tree/mnt")
        let create = Self.run("/usr/bin/hdiutil",
                              ["create", "-size", "10m", "-fs", "APFS", "-volname", "DKTest", img])
        try XCTSkipIf(create.status != 0, "hdiutil create unavailable")
        let attach = Self.run("/usr/bin/hdiutil",
                              ["attach", "-nobrowse", "-mountpoint", mountPoint, img])
        try XCTSkipIf(attach.status != 0, "hdiutil attach unavailable")
        mountedPaths.append(mountPoint)
        try Data(repeating: 1, count: 1_048_576).write(to: URL(fileURLWithPath: mountPoint + "/big.bin"))

        let root = tmp.url.appendingPathComponent("tree")
        let def = try size(root)
        XCTAssertEqual(def.skippedMountPoints.count, 1)
        XCTAssertEqual(def.skippedMountPoints, [mountPoint])
        XCTAssertLessThan(def.logicalBytes, 1_048_576)

        let crossed = try size(root, .init(crossVolumes: true))
        XCTAssertGreaterThanOrEqual(crossed.logicalBytes, 1_048_576)
        XCTAssertTrue(crossed.skippedMountPoints.isEmpty)
    }

    func testHardlinkWithNameOutsideTreeIsExternallyLinked() throws {
        try tmp.file("outside/one.bin", bytes: 1_000_000)
        try tmp.hardlink("tree/in.bin", to: "outside/one.bin")
        try tmp.file("tree/solo.bin", bytes: 10)
        try tmp.file("inner/a.bin", bytes: 100)
        try tmp.hardlink("inner/b.bin", to: "inner/a.bin")
        let r = try size(tmp.url.appendingPathComponent("tree"))
        XCTAssertEqual(r.externallyLinkedFileCount, 1)
        XCTAssertGreaterThanOrEqual(r.externallyLinkedBytes, 1_000_000)
        let inner = try size(tmp.url.appendingPathComponent("inner"))
        XCTAssertEqual(inner.externallyLinkedFileCount, 0)
    }

    func testPrivateAliasRootsAreNotRewritten() throws {
        // /private/var/... must keep its prefix in reported paths, and /private/tmp must be a directory root.
        try skipIfRoot()
        try tmp.dir("tree/locked")
        try tmp.chmod("tree/locked", 0)
        XCTAssertTrue(tmp.url.path.hasPrefix("/private/"), "fixture is expected under /private/var")
        let r = try size(tmp.url.appendingPathComponent("tree"))
        XCTAssertEqual(r.issues.first?.path, tmp.path("tree/locked"))
        let priv = try size(URL(fileURLWithPath: "/private/tmp"))
        XCTAssertEqual(priv.rootKind, .directory)
        XCTAssertGreaterThanOrEqual(priv.directoryCount, 1)
        let viaLink = try size(URL(fileURLWithPath: "/tmp"))
        XCTAssertEqual(viaLink.rootKind, .symlink)
    }

    func testVanishedDirectoryIsCountedOnce() throws {
        // Directory removed after fts listed it: FTS_D then FTS_DNR/ENOENT must not double count.
        try tmp.dir("tree/gone")
        try tmp.file("tree/keep", bytes: 1)
        var opts = FileSizer.Options()
        let root = tmp.path("tree")
        let removed = OSAllocatedUnfairLock(initialState: false)
        opts._entryHook = {
            if removed.withLock({ let was = $0; $0 = true; return !was }) {
                try? FileManager.default.removeItem(atPath: root + "/gone")
            }
        }
        let r = try FileSizer(options: opts).sizeBlocking(of: URL(fileURLWithPath: root))
        XCTAssertLessThanOrEqual(r.directoryCount, 2)
        XCTAssertGreaterThanOrEqual(r.directoryCount, 1)
    }

    // MARK: Errors

    func testMissingRootThrowsRootNotFound() {
        let p = tmp.path("does-not-exist")
        XCTAssertThrowsError(try size(URL(fileURLWithPath: p))) { err in
            XCTAssertEqual(err as? FileSizerError, .rootNotFound(path: p))
        }
    }

    func testNonFileURLThrows() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com"))
        XCTAssertThrowsError(try size(url)) { err in
            guard case .notAFileURL = err as? FileSizerError else {
                return XCTFail("unexpected error \(err)")
            }
        }
    }

    // MARK: Cancellation

    private func makeCancellationFixture() throws {
        for d in 0..<30 {
            for f in 0..<100 { try tmp.file("tree/d\(d)/f\(f)", bytes: 1) }
        }
    }

    func testCancellationStopsWithin100ms() async throws {
        try makeCancellationFixture()
        let counter = OSAllocatedUnfairLock(initialState: 0)
        var opts = FileSizer.Options()
        opts._entryHook = { counter.withLock { $0 += 1 }; usleep(1_000) }
        let sizer = FileSizer(options: opts)
        let root = tmp.url.appendingPathComponent("tree")

        let task = Task { try await sizer.size(of: root) }
        try await Task.sleep(for: .milliseconds(200))
        let t0 = ContinuousClock.now
        task.cancel()
        let result = await task.result
        let elapsed = t0.duration(to: .now)

        guard case .failure(let err) = result else { return XCTFail("expected cancellation") }
        XCTAssertTrue(err is CancellationError, "got \(err)")
        XCTAssertLessThan(elapsed, .milliseconds(100))

        let c1 = counter.withLock { $0 }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(counter.withLock { $0 }, c1, "walk kept running after cancellation")
    }

    func testAlreadyCancelledTaskThrowsBeforeWalking() async throws {
        try tmp.file("tree/a", bytes: 1)
        let counter = OSAllocatedUnfairLock(initialState: 0)
        var opts = FileSizer.Options()
        opts._entryHook = { counter.withLock { $0 += 1 } }
        let sizer = FileSizer(options: opts)
        let root = tmp.url.appendingPathComponent("tree")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await sizer.size(of: root)
        }
        let result = await task.result
        guard case .failure(let err) = result else { return XCTFail("expected failure") }
        XCTAssertTrue(err is CancellationError)
        XCTAssertEqual(counter.withLock { $0 }, 0)
    }

    func testBlockingAPIStopsWhenShouldCancelReturnsTrue() throws {
        for f in 0..<200 { try tmp.file("tree/f\(f)", bytes: 1) }
        let counter = OSAllocatedUnfairLock(initialState: 0)
        var opts = FileSizer.Options()
        opts._entryHook = { counter.withLock { $0 += 1 } }
        let sizer = FileSizer(options: opts)
        XCTAssertThrowsError(try sizer.sizeBlocking(
            of: tmp.url.appendingPathComponent("tree"),
            shouldCancel: { counter.withLock { $0 } >= 50 })) { err in
            XCTAssertTrue(err is CancellationError)
        }
        XCTAssertLessThanOrEqual(counter.withLock { $0 }, 51)
    }

    func testProgressIsReported() throws {
        for f in 0..<100 { try tmp.file("tree/f\(f)", bytes: 1) }
        let seen = OSAllocatedUnfairLock(initialState: [Int]())
        _ = try FileSizer(options: .init(progressInterval: 10)).sizeBlocking(
            of: tmp.url.appendingPathComponent("tree"),
            progress: { p in seen.withLock { $0.append(p.entriesVisited) } })
        let values = seen.withLock { $0 }
        XCTAssertGreaterThanOrEqual(values.count, 9)
        XCTAssertEqual(values, values.sorted())
        XCTAssertEqual(Set(values).count, values.count)
    }

    // MARK: Concurrency and threads

    func testConcurrentSizingIsIndependent() async throws {
        var roots: [URL] = []
        for t in 0..<8 {
            for f in 0..<(20 + t * 5) { try tmp.file("t\(t)/d\(f % 4)/f\(f)", bytes: 100 * (f + 1)) }
            roots.append(tmp.url.appendingPathComponent("t\(t)"))
        }
        let sizer = FileSizer()
        let expected = try roots.map { try sizer.sizeBlocking(of: $0) }
        let cwd = FileManager.default.currentDirectoryPath
        let results = try await withThrowingTaskGroup(of: (Int, SizeReport).self) { group in
            for (i, r) in roots.enumerated() { group.addTask { (i, try await sizer.size(of: r)) } }
            var out = [SizeReport?](repeating: nil, count: roots.count)
            for try await (i, rep) in group { out[i] = rep }
            return out.compactMap { $0 }
        }
        XCTAssertEqual(results, expected)
        XCTAssertEqual(FileManager.default.currentDirectoryPath, cwd)
    }

    func testIOPolicyRestoredOnWalkerThread() throws {
        try tmp.file("tree/a", bytes: 1)
        let root = tmp.url.appendingPathComponent("tree")
        let done = DispatchSemaphore(value: 0)
        let box = OSAllocatedUnfairLock(initialState: (Int32(0), Int32(0)))
        let thread = Thread {
            let before = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
            _ = try? FileSizer().sizeBlocking(of: root)
            let after = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
            box.withLock { $0 = (before, after) }
            done.signal()
        }
        thread.start()
        done.wait()
        let (before, after) = box.withLock { $0 }
        XCTAssertEqual(before, after)
    }

    // MARK: Mtime

    func testNewestModificationIsMaxOverTree() throws {
        try tmp.file("tree/a/b/deep.bin", bytes: 10)
        try tmp.file("tree/a/other.bin", bytes: 10)
        let old = Date(timeIntervalSince1970: 1_577_836_800) // 2020-01-01
        let new = Date(timeIntervalSince1970: 1_748_736_000) // 2025-06-01
        try tmp.setMTime("tree/a/b/deep.bin", old)
        try tmp.setMTime("tree/a/other.bin", old)
        try tmp.setMTime("tree/a/b/deep.bin", new)
        // Directories last, bottom-up.
        try tmp.setMTime("tree/a/b", old)
        try tmp.setMTime("tree/a", old)
        try tmp.setMTime("tree", old)
        let r = try size(tmp.url.appendingPathComponent("tree"))
        XCTAssertEqual(try XCTUnwrap(r.newestModification).timeIntervalSince1970,
                       new.timeIntervalSince1970, accuracy: 1)
    }
}
