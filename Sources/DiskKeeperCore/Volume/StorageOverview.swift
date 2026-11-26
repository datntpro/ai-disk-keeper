import Foundation

public struct StorageOverview: Sendable, Hashable {
    /// `/System/Volumes/Data` (falls back to `/` when missing).
    public let dataVolume: VolumeInfo
    /// `/` (sealed system); nil when it is the same device as the data volume.
    public let systemVolume: VolumeInfo?
    public let snapshots: SnapshotListing
    public let trash: TrashInfo
    public let measuredAt: Date

    public init(dataVolume: VolumeInfo, systemVolume: VolumeInfo?, snapshots: SnapshotListing, trash: TrashInfo, measuredAt: Date) {
        self.dataVolume = dataVolume
        self.systemVolume = systemVolume
        self.snapshots = snapshots
        self.trash = trash
        self.measuredAt = measuredAt
    }

    /// Container capacity minus data used, system used and available: other APFS volumes (Preboot, VM, Recovery, Update) plus snapshots.
    /// nil when this volume's own usage is unknown.
    public var otherVolumesAndSnapshotsBytes: Int64? {
        guard let dataUsed = dataVolume.usedBytesThisVolume else { return nil }
        let systemUsed = systemVolume?.usedBytesThisVolume ?? 0
        return max(0, dataVolume.totalBytes - dataUsed - systemUsed - dataVolume.availableBytes)
    }
}

/// Gathers volume capacity, local snapshots and Trash size concurrently. Read-only. No timers: callers decide when to refresh
/// (the sidebar gauge and menu bar should poll no more than once every 60 s).
public struct StorageOverviewService: Sendable {
    static let dataPath = "/System/Volumes/Data"

    private let volumes: any VolumeInfoProviding
    private let snapshots: LocalSnapshotLister
    private let trash: TrashSizer
    private let now: @Sendable () -> Date

    public init(
        environment: PathEnvironment, volumes: any VolumeInfoProviding = LiveVolumeInfoProvider(),
        snapshots: LocalSnapshotLister = LocalSnapshotLister(), trash: TrashSizer? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.volumes = volumes
        self.snapshots = snapshots
        self.trash = trash ?? TrashSizer(environment: environment)
        self.now = now
    }

    public func overview() async throws -> StorageOverview {
        async let volumePair = loadVolumes()
        async let snaps = snapshots.list(volume: "/")
        async let trashInfo = trash.measure()
        let (data, system) = try await volumePair
        return StorageOverview(
            dataVolume: data, systemVolume: system, snapshots: try await snaps, trash: try await trashInfo, measuredAt: now())
    }

    private func loadVolumes() async throws -> (VolumeInfo, VolumeInfo?) {
        let root = try await volumes.info(forPath: "/")
        let data: VolumeInfo
        do { data = try await volumes.info(forPath: Self.dataPath) } catch is CancellationError {
            throw CancellationError()
        } catch {
            return (root, nil)
        }
        if let a = data.deviceID, let b = root.deviceID, a == b { return (data, nil) }
        return (data, root)
    }
}
