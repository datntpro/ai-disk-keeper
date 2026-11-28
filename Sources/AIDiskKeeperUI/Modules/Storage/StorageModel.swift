import DiskKeeperCore
import Foundation
import Observation

/// The one volume model: the Storage screen, the sidebar gauge, Overview and the menu bar all read this instance
/// (it lives in `suite.state(.storage)`). Read-only: it only asks `StorageOverviewService` to measure.
@MainActor @Observable
final class StorageModel {
    enum Phase: Equatable { case idle, loading, ready, failed(String) }

    private(set) var phase: Phase = .idle
    /// The last good value: kept while refreshing and after a failure.
    private(set) var overview: StorageOverview?
    private(set) var lastRefreshed: Date?
    /// The SSD health card's model lives here so its 10-minute cache survives leaving the Storage screen.
    let ssdHealth: SSDHealthModel

    @ObservationIgnored private let load: @Sendable () async throws -> StorageOverview
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private let minInterval: TimeInterval
    @ObservationIgnored private var lastAttempt: Date?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var rerunForced = false

    init(load: @escaping @Sendable () async throws -> StorageOverview, clock: @escaping () -> Date = Date.init,
         minInterval: TimeInterval = 60, ssdHealth: SSDHealthModel? = nil) {
        self.ssdHealth = ssdHealth ?? SSDHealthModel()
        self.load = load
        self.clock = clock
        self.minInterval = minInterval
    }

    /// Coalesced: one load at a time, and no new one within `minInterval` of the last attempt unless `force`.
    func refresh(force: Bool = false) {
        if task != nil {
            if force { rerunForced = true }
            return
        }
        if !force, let last = lastAttempt, clock().timeIntervalSince(last) < minInterval { return }
        lastAttempt = clock()
        phase = .loading
        let load = load
        task = Task { [weak self] in
            let result: Result<StorageOverview, Error>
            do { result = .success(try await load()) } catch { result = .failure(error) }
            self?.finish(result)
        }
    }

    /// The Trash and the free space changed.
    func noteCleanupFinished() { refresh(force: true) }

    /// Test hook: resolves when no load is running.
    func settle() async {
        while let current = task { await current.value }
    }

    private func finish(_ result: Result<StorageOverview, Error>) {
        task = nil
        switch result {
        case .success(let value):
            overview = value
            lastRefreshed = clock()
            phase = .ready
        case .failure(let error):
            if error is CancellationError { phase = overview == nil ? .idle : .ready } else { phase = .failed(error.localizedDescription) }
        }
        if rerunForced {
            rerunForced = false
            refresh(force: true)
        }
    }

    // MARK: Derived values (pure)

    /// What Finder calls "available": counts purgeable space.
    var freeBytes: Int64? { overview.map { $0.dataVolume.availableForImportantUsage ?? $0.dataVolume.availableBytes } }
    /// Free right now, without macOS freeing anything.
    var strictFreeBytes: Int64? { overview?.dataVolume.availableBytes }
    var purgeableBytes: Int64? { overview?.dataVolume.purgeableEstimate }
    var totalBytes: Int64? { overview?.dataVolume.totalBytes }
    var usedBytes: Int64? {
        guard let total = totalBytes, let free = freeBytes else { return nil }
        return max(0, total - free)
    }
    var usedFraction: Double? {
        guard let total = totalBytes, total > 0, let used = usedBytes else { return nil }
        return min(1, max(0, Double(used) / Double(total)))
    }
    var volumeName: String { overview?.dataVolume.name ?? loc("storage.volumeDefault", "Macintosh HD") }

    /// Bar layers in order. A value that is unknown is omitted, never drawn as zero. Purgeable sits inside the
    /// data volume's used bytes, so "your data" excludes it; the bar's `free` is the strict number.
    /// Labels of the bar layers whose value could not be read, for the bar's accessibility summary.
    var unknownSegmentLabels: [String] {
        guard let overview else { return [] }
        var out: [String] = []
        if overview.dataVolume.usedBytesThisVolume == nil { out.append(loc("storage.layer.data", "Your data")) }
        if overview.systemVolume != nil, overview.systemVolume?.usedBytesThisVolume == nil {
            out.append(loc("storage.layer.system", "macOS (sealed system)"))
        }
        if overview.otherVolumesAndSnapshotsBytes == nil { out.append(loc("storage.layer.other", "Other volumes & snapshots")) }
        return out
    }

    var segments: [StrataSegment] {
        guard let overview else { return [] }
        let purgeable = max(0, purgeableBytes ?? 0)
        var out: [StrataSegment] = []
        if let used = overview.dataVolume.usedBytesThisVolume {
            out.append(StrataSegment(id: "storage.data", layer: .other, bytes: max(0, used - purgeable),
                                     label: loc("storage.layer.data", "Your data")))
        }
        if let system = overview.systemVolume?.usedBytesThisVolume {
            out.append(StrataSegment(id: "storage.system", layer: .apps, bytes: system,
                                     label: loc("storage.layer.system", "macOS (sealed system)")))
        }
        if let other = overview.otherVolumesAndSnapshotsBytes {
            out.append(StrataSegment(id: "storage.other", layer: .junk, bytes: other,
                                     label: loc("storage.layer.other", "Other volumes & snapshots")))
        }
        if purgeableBytes != nil, purgeable > 0 {
            out.append(StrataSegment(id: "storage.purgeable", layer: .build, bytes: purgeable,
                                     label: loc("storage.layer.purgeable", "Purgeable (estimate)")))
        }
        return out
    }
}
