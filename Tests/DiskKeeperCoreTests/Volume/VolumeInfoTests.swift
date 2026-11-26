import XCTest
@testable import DiskKeeperCore

final class VolumeInfoTests: XCTestCase {
    private func vol(avail: Int64, important: Int64?, total: Int64 = 1000) -> VolumeInfo {
        VolumeInfo(mountPath: "/", totalBytes: total, availableBytes: avail, availableForImportantUsage: important)
    }

    func testPurgeableMath() {
        XCTAssertNil(vol(avail: 100, important: nil).purgeableEstimate)
        XCTAssertEqual(vol(avail: 100, important: 300).purgeableEstimate, 200)
        XCTAssertEqual(vol(avail: 100, important: 100).purgeableEstimate, 0)
        XCTAssertEqual(vol(avail: 100, important: 40).purgeableEstimate, 0)   // seen in the wild: clamps
    }

    func testUsedFractionBounds() {
        XCTAssertEqual(vol(avail: 250, important: nil).usedFraction, 0.75, accuracy: 1e-9)
        XCTAssertEqual(vol(avail: 250, important: 500).usedFraction, 0.5, accuracy: 1e-9)   // purgeable counts as free
        XCTAssertEqual(vol(avail: 0, important: nil).usedFraction, 1)                      // full disk, no division by zero
        XCTAssertEqual(vol(avail: 0, important: 5000).usedFraction, 0)                     // clamped
        XCTAssertEqual(vol(avail: 0, important: nil, total: 0).usedFraction, 0)
    }

    func testOtherVolumesNeverNegative() {
        func overview(data: VolumeInfo, system: VolumeInfo?) -> StorageOverview {
            StorageOverview(dataVolume: data, systemVolume: system, snapshots: .listed([]),
                            trash: TrashInfo(path: "/x", state: .measured, allocatedBytes: 0, itemCount: 0), measuredAt: Date())
        }
        let data = VolumeInfo(mountPath: "/d", totalBytes: 1000, availableBytes: 100, usedBytesThisVolume: 600)
        let sys = VolumeInfo(mountPath: "/", totalBytes: 1000, availableBytes: 100, usedBytesThisVolume: 50)
        XCTAssertEqual(overview(data: data, system: sys).otherVolumesAndSnapshotsBytes, 250)
        let over = VolumeInfo(mountPath: "/d", totalBytes: 1000, availableBytes: 100, usedBytesThisVolume: 990)
        XCTAssertEqual(overview(data: over, system: sys).otherVolumesAndSnapshotsBytes, 0)
        let unknown = VolumeInfo(mountPath: "/d", totalBytes: 1000, availableBytes: 100)
        XCTAssertNil(overview(data: unknown, system: nil).otherVolumesAndSnapshotsBytes)
    }

    func testLiveProviderReturnsSaneValuesForRoot() async throws {
        // Reads volume metadata only, never files.
        let v = try await LiveVolumeInfoProvider().info(forPath: "/")
        XCTAssertGreaterThan(v.totalBytes, 0)
        XCTAssertLessThanOrEqual(v.availableBytes, v.totalBytes)
        XCTAssertEqual(v.mountPath, "/")
    }

    func testLiveProviderThrowsForMissingPath() async {
        do {
            _ = try await LiveVolumeInfoProvider().info(forPath: "/definitely/not/here-\(UUID().uuidString)")
            XCTFail("expected throw")
        } catch is VolumeInfoError {}
        catch { XCTFail("\(error)") }
    }

    func testExplanationsAreNonEmptyAndFinished() {
        for e in StorageExplanation.allCases {
            XCTAssertFalse(e.englishText.isEmpty)
            XCTAssertFalse(e.englishText.contains("TODO"))
        }
    }
}

/// Live checks against this Mac's real volumes. Skipped unless the boot volume is APFS with a separate Data volume.
final class VolumeLiveSanityTests: XCTestCase {
    private func diskutilCapacityInUse(_ path: String) throws -> Int64? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        p.arguments = ["info", "-plist", path]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0,
              let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return (plist["CapacityInUse"] as? NSNumber)?.int64Value
    }

    func testPerVolumeUsedMatchesDiskutilAndVolumesAreDistinct() async throws {
        let provider = LiveVolumeInfoProvider()
        let root = try await provider.info(forPath: "/")
        try XCTSkipUnless(root.fileSystem == "apfs", "boot volume is not APFS")
        let dataPath = "/System/Volumes/Data"
        try XCTSkipUnless(FileManager.default.fileExists(atPath: dataPath), "no separate Data volume")
        let data = try await provider.info(forPath: dataPath)

        XCTAssertNotNil(root.fileSystemID)
        XCTAssertNotEqual(root.fileSystemID, data.fileSystemID, "/ and Data must be told apart (st_dev can't)")

        let rootUsed = try XCTUnwrap(root.usedBytesThisVolume)
        let dataUsed = try XCTUnwrap(data.usedBytesThisVolume)
        XCTAssertNotEqual(rootUsed, dataUsed, "used must be per volume, not container-wide")
        XCTAssertLessThanOrEqual(rootUsed + dataUsed, data.totalBytes - data.availableBytes)

        // The Data volume changes while we run (caches, logs): allow 1 GiB of drift. The sealed system volume is stable.
        for (info, path, slack) in [(root, "/", Int64(64 << 20)), (data, dataPath, Int64(1 << 30))] {
            guard let expected = try diskutilCapacityInUse(path) else { throw XCTSkip("diskutil unavailable") }
            XCTAssertLessThan(abs(info.usedBytesThisVolume! - expected), slack, "\(path) used vs diskutil")
        }

        let overview = try await StorageOverviewService(
            environment: .current(), snapshots: LocalSnapshotLister(executable: URL(fileURLWithPath: "/nonexistent/tmutil")),
            trash: TrashSizer(environment: .current()) { _ in throw FileSizerError.rootNotFound(path: "x") }).overview()
        XCTAssertNotNil(overview.systemVolume)
        XCTAssertNotNil(overview.otherVolumesAndSnapshotsBytes)
    }
}
