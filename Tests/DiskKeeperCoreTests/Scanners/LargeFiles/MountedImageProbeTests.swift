import Foundation
import XCTest
@testable import DiskKeeperCore

final class MountedImageProbeTests: XCTestCase {
    private func report(_ fx: FixtureHome, mounted: FakeMountedImages) async throws -> LargeFileReport {
        let tree = try await IndexTest.index(fx)
        return try await LargeFix.scanner(fx, mounted: mounted).report(tree: tree, now: LargeFix.now)
    }

    func testMountedDmgIsKeepAndNotSelectable() async throws {
        let fx = try FixtureHome()
        let mounted = try LargeFix.sparse(fx.abs("Downloads/Tool.dmg"), logical: 300 * LargeFix.mb)
        try LargeFix.sparse(fx.abs("Downloads/Other.dmg"), logical: 300 * LargeFix.mb)
        let r = try await report(fx, mounted: FakeMountedImages(paths: [MountedImagePaths.key(mounted)]))
        let tool = try XCTUnwrap(r.files.first { $0.name == "Tool.dmg" })
        let other = try XCTUnwrap(r.files.first { $0.name == "Other.dmg" })
        XCTAssertTrue(tool.isMountedImage)
        XCTAssertFalse(other.isMountedImage)
        let toolItem = LargeFileScanner.makeItem(tool)
        XCTAssertEqual(toolItem.tier, .keep)
        XCTAssertFalse(toolItem.isSelectable)
        XCTAssertTrue(toolItem.explanation.contains("eject it first"))
        let otherItem = LargeFileScanner.makeItem(other)
        XCTAssertEqual(otherItem.tier, .review)
        XCTAssertTrue(otherItem.isSelectable)
        XCTAssertTrue(r.warnings.isEmpty)
    }

    func testCaseFoldedMatch() async throws {
        let fx = try FixtureHome()
        let p = try LargeFix.sparse(fx.abs("Downloads/Tool.dmg"), logical: 300 * LargeFix.mb)
        let r = try await report(fx, mounted: FakeMountedImages(paths: [MountedImagePaths.key(p).lowercased()]))
        XCTAssertTrue(try XCTUnwrap(r.files.first).isMountedImage)
    }

    func testProbeFailureChangesNothingAndWarnsOnce() async throws {
        let fx = try FixtureHome()
        try LargeFix.sparse(fx.abs("Downloads/Tool.dmg"), logical: 300 * LargeFix.mb)
        try LargeFix.sparse(fx.abs("Downloads/Two.dmg"), logical: 300 * LargeFix.mb)
        let r = try await report(fx, mounted: FakeMountedImages(error: MountedImageProbeError.unreadable))
        XCTAssertEqual(r.files.count, 2)
        XCTAssertFalse(r.files.contains { $0.isMountedImage })
        XCTAssertEqual(r.warnings.count, 1)
        XCTAssertEqual(r.warnings.first?.kind, .scannerFailed)
    }

    func testHdiutilPlistParsing() throws {
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict><key>images</key><array>
        <dict><key>image-path</key><string>/Users/x/Downloads/A.dmg</string></dict>
        <dict><key>image-type</key><string>no path</string></dict>
        </array></dict></plist>
        """
        let set = try SystemMountedImageProbe.parse(plist: Data(plist.utf8))
        XCTAssertEqual(set, [MountedImagePaths.key("/Users/x/Downloads/A.dmg")])
        XCTAssertThrowsError(try SystemMountedImageProbe.parse(plist: Data("nope".utf8)))
    }

    func testRawPathParsing() {
        XCTAssertEqual(MountedImagePaths.path(fromRaw: "file:///Users/x/My%20Disk.dmg\0"), "/Users/x/My Disk.dmg")
        XCTAssertEqual(MountedImagePaths.path(fromRaw: "/a/b.dmg"), "/a/b.dmg")
        XCTAssertNil(MountedImagePaths.path(fromRaw: "relative.dmg"))
        XCTAssertNil(MountedImagePaths.path(fromRaw: ""))
    }

    func testRegistryFallbackToHdiutilOnlyWhenRegistryUnavailable() async throws {
        let probe = SystemMountedImageProbe(registry: { ["from-registry"] })
        let got = try await probe.mountedImagePaths()
        XCTAssertEqual(got, ["from-registry"])
        let empty = SystemMountedImageProbe(registry: { [] })
        let none = try await empty.mountedImagePaths()
        XCTAssertTrue(none.isEmpty)
    }

    func testSharedPillHiddenBelowOnePercent() {
        func file(allocated: Int64, reclaimable: Int64?, shares: Bool = true, all: Bool = false, links: UInt16 = 1) -> LargeFile {
            LargeFile(path: "/x/a.bin", logicalBytes: allocated, allocatedBytes: allocated, reclaimableBytes: reclaimable,
                      kind: .other, dates: LargeFix.old(), lastOpened: LargeFix.now, lastOpenedSource: .modified,
                      installedAppMatch: nil, sharesStorage: shares, sharesAllStorage: all, linkCount: links)
        }
        XCTAssertFalse(file(allocated: 1000, reclaimable: 995).showsSharedStoragePill)   // 0.5% shared
        XCTAssertTrue(file(allocated: 1000, reclaimable: 980).showsSharedStoragePill)    // 2% shared
        XCTAssertTrue(file(allocated: 1000, reclaimable: nil).showsSharedStoragePill)
        XCTAssertTrue(file(allocated: 1000, reclaimable: 0, all: true).showsSharedStoragePill)
        XCTAssertTrue(file(allocated: 1000, reclaimable: 999, links: 2).showsSharedStoragePill)
        XCTAssertFalse(file(allocated: 1000, reclaimable: 0, shares: false).showsSharedStoragePill)
    }

    func testLastOpenedTieBreak() {
        let d = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(FileDates(spotlightLastUsed: d, accessed: d, modified: d, created: d).lastOpened.source, .spotlight)
        XCTAssertEqual(FileDates(spotlightLastUsed: nil, accessed: d, modified: d, created: d).lastOpened.source, .modified)
    }
}
