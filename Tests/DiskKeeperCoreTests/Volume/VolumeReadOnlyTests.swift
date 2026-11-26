import XCTest
@testable import DiskKeeperCore

final class VolumeReadOnlyTests: XCTestCase {
    func testNoTmutilWriteSubcommandAnywhere() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sources = root.appendingPathComponent("Sources")
        let en = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var scanned = 0
        for case let url as URL in en where url.pathExtension == "swift" {
            scanned += 1
            let text = try String(contentsOf: url, encoding: .utf8)
            let rel = url.path.replacingOccurrences(of: sources.path + "/", with: "")
            for banned in ["deletelocalsnapshots", "thinlocalsnapshots", "diskutil", "\"purge\"", "\"disable\""] {
                XCTAssertFalse(text.contains(banned), "\(rel) contains \(banned)")
            }
            if rel != "DiskKeeperCore/Volume/LocalSnapshots.swift" {
                XCTAssertFalse(text.contains("tmutil"), "\(rel) mentions tmutil")
            }
        }
        XCTAssertGreaterThan(scanned, 10)
        XCTAssertEqual(LocalSnapshotLister.arguments, ["listlocalsnapshots"])
    }

    func testServiceDoesNotModifyFixture() async throws {
        let fx = try FixtureHome()
        _ = try fx.file(".Trash/a", bytes: 100)
        _ = try fx.file("Documents/b", bytes: 100)
        let before = try fx.snapshot()
        let svc = StorageOverviewService(
            environment: fx.env, snapshots: LocalSnapshotLister(executable: URL(fileURLWithPath: "/nonexistent/tmutil")))
        _ = try await svc.overview()
        XCTAssertEqual(try fx.snapshot(), before)
    }
}
