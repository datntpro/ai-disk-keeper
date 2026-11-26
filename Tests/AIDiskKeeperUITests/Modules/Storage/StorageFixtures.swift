import DiskKeeperCore
import Foundation

enum StorageFix {
    static let gb: Int64 = 1_000_000_000
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// 494 GB container; strict available 150, important 182 (so purgeable 32); data 280, system 12.
    static func volume(important: Int64? = 182 * gb, used: Int64? = 280 * gb) -> VolumeInfo {
        VolumeInfo(mountPath: "/System/Volumes/Data", name: "Macintosh HD", fileSystem: "APFS", totalBytes: 494 * gb,
                   availableBytes: 150 * gb, availableForImportantUsage: important, usedBytesThisVolume: used, isInternal: true)
    }

    static func overview(
        important: Int64? = 182 * gb, used: Int64? = 280 * gb,
        snapshots: SnapshotListing = .listed([LocalSnapshot(name: "com.apple.TimeMachine.2026-11-26-101010.local", date: now, kind: .timeMachine)]),
        trash: TrashInfo = TrashInfo(path: "/h/.Trash", state: .measured, allocatedBytes: 3 * gb, itemCount: 12)
    ) -> StorageOverview {
        StorageOverview(dataVolume: volume(important: important, used: used),
                        systemVolume: VolumeInfo(mountPath: "/", totalBytes: 494 * gb, availableBytes: 150 * gb, usedBytesThisVolume: 12 * gb),
                        snapshots: snapshots, trash: trash, measuredAt: now)
    }
}

/// Counts loads and can be told to fail or hang.
actor LoadCounter {
    private(set) var count = 0
    private var results: [Result<StorageOverview, Error>]
    init(_ results: [Result<StorageOverview, Error>]) { self.results = results }
    func next() throws -> StorageOverview {
        count += 1
        let r = results.count > 1 ? results.removeFirst() : results[0]
        return try r.get()
    }
}

struct StorageFixError: Error, LocalizedError { var errorDescription: String? { "boom" } }
