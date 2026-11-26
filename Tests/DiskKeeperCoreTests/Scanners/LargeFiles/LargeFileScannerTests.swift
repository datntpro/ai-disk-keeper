import Darwin
import Foundation
import XCTest
@testable import DiskKeeperCore

final class LargeFileScannerTests: XCTestCase {
    func testFloorScopeAndHiddenFilters() async throws {
        let fx = try FixtureHome()
        let mb = LargeFix.mb
        try LargeFix.sparse(fx.abs("Movies/big.mov"), logical: 600 * mb)
        try LargeFix.sparse(fx.abs("Movies/exact.mov"), logical: 100 * mb)
        try LargeFix.sparse(fx.abs("Movies/below.mov"), logical: 100 * mb - 1)
        try LargeFix.sparse(fx.abs("Library/Caches/lib.bin"), logical: 600 * mb)
        try LargeFix.sparse(fx.abs(".ollama/models/m.bin"), logical: 600 * mb)
        try LargeFix.sparse(fx.abs("Documents/.hidden/h.bin"), logical: 600 * mb)
        try LargeFix.sparse(fx.abs("$TMP/outside.bin"), logical: 600 * mb)
        let report = try await LargeFix.report(fx)
        XCTAssertEqual(Set(report.files.map(\.name)), ["big.mov", "exact.mov"])
    }

    func testOutsideScopeExcluded() async throws {
        let fx = try FixtureHome()
        try LargeFix.sparse(fx.abs("a/in.bin"), logical: 300 * LargeFix.mb)
        try LargeFix.sparse(fx.abs("b/out.bin"), logical: 300 * LargeFix.mb)
        let tree = try await IndexTest.index(fx)
        let s = LargeFix.scanner(fx) { $0.scopeRoot = fx.abs("a") }
        let report = try await s.report(tree: tree, now: LargeFix.now)
        XCTAssertEqual(report.files.map(\.name), ["in.bin"])
    }

    func testSyntheticFlagsAreSkipped() async throws {
        let root = "/tmp/lf-home"
        let big: Int64 = 600 * LargeFix.mb
        let tree = LargeFix.tree(root: root, files: [
            ("\(root)/ok.zip", [], [], big, 1),
            ("\(root)/cloud.zip", .dataless, [], big, 2),
            ("\(root)/node-cloud.zip", [], .dataless, big, 3),
            ("\(root)/prot.zip", .protected, [], big, 4),
            ("\(root)/Pictures/Photos.photoslibrary/o.jpg", .protected, [], big, 5),
            ("\(root)/Music/lib.bin", .outsideCleanableRoots, [], big, 6),
            ("\(root)/link.zip", .hardlinkRepeat, [], big, 7),
            ("\(root)/bad.zip", .nonUTF8Name, [], big, 8),
        ])
        var o = LargeFileOptions(scopeRoot: root, excludedRoots: [root + "/Library"])
        o.minimumBytes = 100 * LargeFix.mb
        let s = LargeFileScanner(options: o, lastOpened: FakeLastOpened(fallback: LargeFix.old()), appNames: FakeApps(apps: []),
                                 tree: { tree })
        // none of the synthetic paths exist, so even ok.zip is dropped by the lstat identity check
        let report = try await s.report(tree: tree, now: LargeFix.now)
        XCTAssertTrue(report.files.isEmpty)
        XCTAssertEqual(report.skipped.dataless, 2)
        XCTAssertEqual(report.skipped.protected, 4)
        XCTAssertEqual(report.skipped.hardLinkRepeat, 1)
        XCTAssertEqual(report.skipped.changed, 1)
    }

    func testPhotosLibraryEndToEnd() async throws {
        let fx = try FixtureHome()
        try LargeFix.sparse(fx.abs("Pictures/Photos Library.photoslibrary/originals/a.heic"), logical: 300 * LargeFix.mb)
        try LargeFix.sparse(fx.abs("Pictures/plain.bin"), logical: 300 * LargeFix.mb)
        let report = try await LargeFix.report(fx)
        XCTAssertEqual(report.files.map(\.name), ["plain.bin"])
    }

    func testChangedFileIsDropped() async throws {
        let fx = try FixtureHome()
        let p = try LargeFix.sparse(fx.abs("a.bin"), logical: 300 * LargeFix.mb)
        let tree = try await IndexTest.index(fx)
        try FileManager.default.removeItem(atPath: p)
        try LargeFix.sparse(p, logical: 300 * LargeFix.mb)   // new inode
        let report = try await LargeFix.scanner(fx).report(tree: tree, now: LargeFix.now)
        XCTAssertTrue(report.files.isEmpty)
        XCTAssertEqual(report.skipped.changed, 1)
    }

    func testHardLinkIsReportOnly() async throws {
        let fx = try FixtureHome()
        let a = try LargeFix.sparse(fx.abs("a.bin"), logical: 300 * LargeFix.mb)
        XCTAssertEqual(Darwin.link(a, fx.abs("b.bin")), 0)
        let report = try await LargeFix.report(fx)
        XCTAssertEqual(report.files.count, 1)
        let f = try XCTUnwrap(report.files.first)
        XCTAssertGreaterThan(f.linkCount, 1)
        XCTAssertTrue(f.sharesStorage)
        let item = LargeFileScanner.makeItem(f)
        XCTAssertEqual(item.cleanupMethod, CleanupMethod.none)
        XCTAssertFalse(item.isSelectable)
        XCTAssertTrue(item.flags.contains(.sharedStorage))
    }

    func testCloneSharesStorage() async throws {
        let fx = try FixtureHome()
        let a = try DupFix.write(fx.abs("a.bin"), DupFix.data(seed: 9, count: 2_000_000))
        try DupFix.clone(a, fx.abs("b.bin"))
        let tree = try await IndexTest.index(fx)
        var s = LargeFix.scanner(fx, minimum: 1_000_000)
        s._cloneProbe = nil   // the real APFS probe
        let report = try await s.report(tree: tree, now: LargeFix.now)
        XCTAssertEqual(report.files.count, 2)
        XCTAssertTrue(report.files.allSatisfy(\.sharesStorage))
    }

    func testLastOpenedMaxAndSource() {
        let base = Date(timeIntervalSince1970: 1_000_000)
        func d(_ n: Double) -> Date { base.addingTimeInterval(n) }
        XCTAssertEqual(FileDates(spotlightLastUsed: d(30), accessed: d(20), modified: d(10), created: d(0)).lastOpened.source, .spotlight)
        XCTAssertEqual(FileDates(spotlightLastUsed: d(5), accessed: d(20), modified: d(10), created: d(0)).lastOpened.source, .accessed)
        XCTAssertEqual(FileDates(spotlightLastUsed: nil, accessed: d(5), modified: d(10), created: d(0)).lastOpened.source, .modified)
        XCTAssertEqual(FileDates(spotlightLastUsed: nil, accessed: nil, modified: d(10), created: d(0)).lastOpened.date, d(10))
        // tie → Spotlight wins
        XCTAssertEqual(FileDates(spotlightLastUsed: d(10), accessed: d(10), modified: d(10), created: d(0)).lastOpened.source, .spotlight)
    }

    func testReportCarriesLastOpened() async throws {
        let fx = try FixtureHome()
        let p = try LargeFix.sparse(fx.abs("a.bin"), logical: 300 * LargeFix.mb)
        let recent = LargeFix.now.addingTimeInterval(-10)
        var table = FakeLastOpened()
        table.table[p] = FileDates(spotlightLastUsed: recent, accessed: LargeFix.now.addingTimeInterval(-1000),
                                   modified: LargeFix.now.addingTimeInterval(-9000), created: LargeFix.now.addingTimeInterval(-9000))
        let report = try await LargeFix.report(fx, dates: table)
        XCTAssertEqual(report.files.first?.lastOpened, recent)
        XCTAssertEqual(report.files.first?.lastOpenedSource, .spotlight)
    }

    func testInstallerHint() async throws {
        let fx = try FixtureHome()
        let mb = LargeFix.mb
        try LargeFix.sparse(fx.abs("Downloads/Xcode_16.2.xip"), logical: 300 * mb)
        try LargeFix.sparse(fx.abs("Downloads/Docker.dmg"), logical: 300 * mb)
        try LargeFix.sparse(fx.abs("Downloads/Dock.dmg"), logical: 300 * mb)
        try LargeFix.sparse(fx.abs("Downloads/Éditeur-1.2-Installer.dmg"), logical: 300 * mb)
        try LargeFix.sparse(fx.abs("Downloads/Docker.zip"), logical: 300 * mb)
        try LargeFix.sparse(fx.abs("Documents/Docker.zip"), logical: 300 * mb)
        try LargeFix.sparse(fx.abs("Downloads/Xcode.mov"), logical: 300 * mb)
        let report = try await LargeFix.report(fx, apps: ["Xcode", "Docker", "Editeur"])
        func match(_ p: String) -> String? { report.files.first { $0.path == fx.abs(p) }?.installedAppMatch }
        XCTAssertEqual(match("Downloads/Xcode_16.2.xip"), "Xcode")
        XCTAssertEqual(match("Downloads/Docker.dmg"), "Docker")
        XCTAssertNil(match("Downloads/Dock.dmg"))
        XCTAssertEqual(match("Downloads/Éditeur-1.2-Installer.dmg"), "Editeur")
        XCTAssertEqual(match("Downloads/Docker.zip"), "Docker")
        XCTAssertNil(match("Documents/Docker.zip"))
        XCTAssertNil(match("Downloads/Xcode.mov"))
    }

    func testNormalize() {
        XCTAssertEqual(ApplicationsFolderNames.normalize("Visual Studio Code"), "visualstudiocode")
        XCTAssertEqual(ApplicationsFolderNames.normalize("Foo-1.2.3-arm64-macOS_Installer"), "foo")
        XCTAssertEqual(ApplicationsFolderNames.normalize("Café_v3"), "cafe")
    }

    func testSortedByAllocatedThenPath() async throws {
        let fx = try FixtureHome()
        for n in ["b", "a", "c"] { try LargeFix.sparse(fx.abs("\(n).bin"), logical: 300 * LargeFix.mb) }
        let report = try await LargeFix.report(fx)
        XCTAssertEqual(report.files.map(\.name), ["a.bin", "b.bin", "c.bin"])
    }

    func testItemsAreNeverSafe() async throws {
        let fx = try FixtureHome()
        var kinds = LargeFileKind.allCases.makeIterator()
        for (i, ext) in ["zip", "dmg", "mov", "vmdk", "bin"].enumerated() {
            try LargeFix.sparse(fx.abs("f\(i).\(ext)"), logical: 300 * LargeFix.mb)
            _ = kinds.next()
        }
        let report = try await LargeFix.report(fx)
        XCTAssertEqual(report.files.count, 5)
        for f in report.files {
            let item = LargeFileScanner.makeItem(f)
            XCTAssertEqual(item.tier, .review)
            XCTAssertFalse(item.isBulkSelectable)
            XCTAssertEqual(item.category, .largeFile)
            XCTAssertEqual(item.ruleID, "large.\(f.kind.rawValue)")
            XCTAssertEqual(item.lastModified, f.dates.modified)
        }
    }

    func testScanAppliesGuardAndOwnerFilters() async throws {
        let fx = try FixtureHome()
        try LargeFix.sparse(fx.abs("a.bin"), logical: 300 * LargeFix.mb)
        let tree = try await IndexTest.index(fx)
        var s = LargeFileScanner(options: { var o = LargeFileOptions(environment: fx.env); o.minimumBytes = 100 * LargeFix.mb; return o }(),
                                 lastOpened: FakeLastOpened(fallback: LargeFix.old()), appNames: FakeApps(apps: []), tree: { tree })
        s._cloneProbe = { _ in .unknown }
        let guardian = try ScanGuard(environment: fx.env, protectPatterns: [])
        func run(user: uid_t) async throws -> (items: [ScanItem], progress: ScannerProgress) {
            let ctx = ScanContext(environment: fx.env, pathGuard: guardian, now: LargeFix.now, userID: user)
            let box = Box()
            let sink = ScanSink(item: { await box.add($0) }, warning: { _ in }, progress: { await box.set($0) })
            try await s.scan(context: ctx, sink: sink)
            return (await box.items, await box.progress)
        }
        let ok = try await run(user: getuid())
        XCTAssertEqual(ok.items.count, 1)
        let other = try await run(user: getuid() &+ 1)
        XCTAssertTrue(other.items.isEmpty)
        XCTAssertEqual(other.progress.ownerDropped, 1)
    }

    func testScannerSourcesHaveNoWriteAPIs() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let dir = root.appendingPathComponent("Sources/DiskKeeperCore/Scanners/LargeFiles")
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".swift") }
        XCTAssertGreaterThanOrEqual(files.count, 6)
        let banned = ["CleanupEngine", "trashItem", "removeItem", "moveItem", "copyItem", "createFile", "unlink(", "rename(",
                      "setAttributes", "FileHandle", "fopen", "open(", "write("]
        for f in files {
            let text = try String(contentsOf: dir.appendingPathComponent(f), encoding: .utf8)
            for b in banned { XCTAssertFalse(text.contains(b), "\(f) mentions \(b)") }
        }
    }
}

private actor Box {
    var items: [ScanItem] = []
    var progress = ScannerProgress()
    func add(_ i: ScanItem) { items.append(i) }
    func set(_ p: ScannerProgress) { progress = p }
}
