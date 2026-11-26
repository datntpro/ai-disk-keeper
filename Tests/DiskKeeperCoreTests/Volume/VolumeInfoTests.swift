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
