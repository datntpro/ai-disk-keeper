import AppKit
import DiskKeeperCore
import Foundation
import Observation
import SwiftUI

/// Free and total bytes of the data volume: the only thing the 60 s poll measures.
struct VolumeCapacity: Equatable, Sendable {
    var free: Int64
    var total: Int64

    /// Two `URLResourceValues` reads: no Trash walk, no child process. Free counts purgeable space, like Finder.
    static let live: @Sendable () -> VolumeCapacity? = {
        // The Data volume everywhere (`/` only when it is missing); never the sealed system volume.
        for path in [DataVolume.path] {
            let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
            guard let v = try? URL(fileURLWithPath: path).resourceValues(forKeys: keys), let total = v.volumeTotalCapacity,
                  let free = v.volumeAvailableCapacityForImportantUsage ?? v.volumeAvailableCapacity.map(Int64.init) else { continue }
            return VolumeCapacity(free: free, total: Int64(total))
        }
        return nil
    }
}

/// What the menu bar popover shows, derived from the window's own models (the same instances: storage, care, scan),
/// plus the volume poll that feeds the low-space alert (driven by `MonitorScheduler`, every 60 s). Read-only: nothing here selects, cleans or deletes.
@MainActor @Observable
final class MenuBarModel {
    let storage: StorageModel
    let care: CareScanModel
    let scan: ScanViewModel
    let settings: SettingsModel

    /// The "Next Care Scan" row stays hidden until scheduled scans (#23) exist.
    var nextScheduledScan: Date?

    /// The last cheap poll result and when it was taken; the full overview wins only when it is newer.
    private var polled: (capacity: VolumeCapacity, at: Date)?

    @ObservationIgnored private let probe: @Sendable () -> VolumeCapacity?
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private let notifier: any LowSpaceNotifying
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var monitor: LowSpaceMonitor
    @ObservationIgnored private var lastThreshold: Int?
    @ObservationIgnored private var history: FreeSpaceHistory
    @ObservationIgnored private let historyStore: FreeSpaceHistoryStore?
    /// Where free space is heading (D6); nil until six hours of history exist.
    private(set) var trend: FreeSpaceTrend.Trend?

    init(storage: StorageModel, care: CareScanModel, scan: ScanViewModel, settings: SettingsModel,
         notifier: any LowSpaceNotifying, defaults: UserDefaults = .standard,
         probe: @escaping @Sendable () -> VolumeCapacity? = VolumeCapacity.live, clock: @escaping () -> Date = Date.init,
         historyStore: FreeSpaceHistoryStore? = nil) {
        self.historyStore = historyStore
        self.history = historyStore?.load() ?? FreeSpaceHistory()
        self.probe = probe
        self.clock = clock
        self.storage = storage
        self.care = care
        self.scan = scan
        self.settings = settings
        self.notifier = notifier
        self.defaults = defaults
        self.monitor = LowSpaceMonitor.load(from: defaults)
        self.trend = FreeSpaceTrend.estimate(history.points, now: clock())
    }

    // MARK: Derived (pure)

    /// The newer of the poll's capacity and the full overview (which a cleanup or the popover refreshes on demand).
    private var currentCapacity: VolumeCapacity? {
        let fromOverview = storage.freeBytes.flatMap { free in storage.totalBytes.map { VolumeCapacity(free: free, total: $0) } }
        guard let polled else { return fromOverview }
        if let fromOverview, let at = storage.lastRefreshed, at > polled.at { return fromOverview }
        return polled.capacity
    }

    var freeBytes: Int64? { currentCapacity?.free }
    var usedFraction: Double? { storage.usedFraction }
    var volumeName: String { storage.volumeName }

    var freeFraction: Double? {
        guard let c = currentCapacity, c.total > 0 else { return nil }
        return min(1, max(0, Double(c.free) / Double(c.total)))
    }

    /// The Care Scan's deduped Safe total; before one exists, the rule scan's Safe total. Nil before any scan
    /// and while a Care Scan runs.
    var safeBytes: Int64? {
        if care.phase == .scanning { return nil }
        if let totals = care.totals { return totals.safeBytes }
        guard scan.phase == .finished || scan.phase == .cancelled else { return nil }
        return scan.totals.byTier[.safe]?.allocatedBytes
    }

    var lastScanAt: Date? { care.lastFinishedAt ?? scan.lastScanFinishedAt }
    var isScanning: Bool { care.isBusy || scan.isScanning }

    /// AI-tool growth since the last scan, hidden under ±100 MB.
    var aiGrowth: Int64? {
        guard let growth = care.growth, abs(growth.aiToolsDelta) >= CareScanModel.growthThreshold else { return nil }
        return growth.aiToolsDelta
    }

    /// The five biggest AI tools by allocated bytes (their AI-tool data items), after a scan.
    var topTools: [(tool: ToolID, bytes: Int64)] {
        var sums: [ToolID: Int64] = [:]
        for item in scan.items where item.category == .aiToolData { sums[item.tool, default: 0] += item.sizeAllocated }
        return sums.filter { $0.value > 0 }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key.rawValue < $1.key.rawValue }
            .prefix(5).map { (tool: $0.key, bytes: $0.value) }
    }

    /// The module with the most Safe bytes ("System junk · 7.4 GB Safe").
    var topSafeModule: (module: CareModule, bytes: Int64)? {
        care.summaries.values.filter { $0.safeBytes > 0 }
            .max { $0.safeBytes != $1.safeBytes ? $0.safeBytes < $1.safeBytes : $0.module.rawValue > $1.module.rawValue }
            .map { (module: $0.module, bytes: $0.safeBytes) }
    }

    /// The popover's status item label ("182 GB") when the setting is on.
    var labelFreeText: String? {
        guard settings.settings.menuBarShowsFreeSpace, let free = freeBytes else { return nil }
        return Formatting.bytes(free)
    }

    /// ok / warning / critical against the user's threshold (default 15 %); critical below 5 % or 10 GB.
    var freeSpaceStatus: FreeSpaceStatus? {
        guard let c = currentCapacity else { return nil }
        return FreeSpaceStatus(freeBytes: c.free, totalBytes: c.total, thresholdPercent: settings.settings.lowSpaceThresholdPercent, trend: trend)
    }

    var freeSpaceLevel: FreeSpaceLevel { freeSpaceStatus?.level ?? .ok }

    /// "Full in about 2 days at the current rate" / "Free space is stable"; nil while there is no trend.
    var trendText: String? {
        guard let trend else { return nil }
        guard let eta = trend.timeToFull else { return FreeSpaceCopy.stable }
        return FreeSpaceCopy.fullIn(FreeSpaceCopy.duration(eta))
    }

    /// "Low disk space: 13% free" while the level is not ok, else the plain label.
    var lowSpaceAccessibility: String? {
        guard let status = freeSpaceStatus, status.level != .ok else { return nil }
        let percent = MonitorFormatting.percent(status.freeFraction)
        return status.level == .critical ? FreeSpaceCopy.criticalA11y(percent) : FreeSpaceCopy.lowA11y(percent)
    }

    var labelAccessibility: String {
        MenuBarCopy.labelA11y(freeBytes.map { Formatting.bytes($0) } ?? "—")
    }

    /// `MenuBarExtra(isInserted:)` reads and writes the persisted setting.
    static func insertedBinding(_ settings: SettingsModel) -> Binding<Bool> {
        Binding(get: { settings.settings.showMenuBarItem }, set: { settings.setShowMenuBarItem($0) })
    }

    private static let saveQueue = DispatchQueue(label: "adk.free-space-history", qos: .utility)

    // MARK: Poll

    /// One poll step: read the volume's capacity (cheap), then feed the alert. Never touches `StorageModel`, so the
    /// poll does not walk the Trash or spawn a child process.
    func tick() async {
        if let capacity = probe() {
            polled = (capacity, clock())
            recordHistory(capacity)
        }
        await evaluateLowSpace()
    }

    /// Feeds the 10-minute free-space history; the file is written only when a new bucket opens.
    private func recordHistory(_ capacity: VolumeCapacity) {
        let now = clock()
        let opened = history.record(freeBytes: capacity.free, at: now)
        trend = FreeSpaceTrend.estimate(history.points, now: now)
        if opened, let store = historyStore {
            let snapshot = history
            Self.saveQueue.async { try? store.save(snapshot) }   // serial: an older snapshot never lands after a newer one
        }
    }

    /// The popover opened: refresh the full overview (coalesced by `StorageModel`).
    func popoverOpened() { storage.refresh() }

    func evaluateLowSpace() async {
        guard settings.settings.lowSpaceAlertEnabled, let fraction = freeFraction, let free = freeBytes else { return }
        let percent = settings.settings.lowSpaceThresholdPercent
        let threshold = Double(percent) / 100
        if let last = lastThreshold, last != percent {
            lastThreshold = percent
            monitor.thresholdChanged(freeFraction: fraction, threshold: threshold)
            monitor.save(to: defaults)
            return
        }
        lastThreshold = percent
        let fire = monitor.observe(freeFraction: fraction, threshold: threshold)
        monitor.save(to: defaults)
        if fire { await notifier.notify(freeBytes: free, percent: Int((fraction * 100).rounded())) }
    }
}
