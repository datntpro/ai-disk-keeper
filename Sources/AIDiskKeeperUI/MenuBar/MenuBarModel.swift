import AppKit
import DiskKeeperCore
import Foundation
import Observation
import SwiftUI

/// What the menu bar popover shows, derived from the window's own models (the same instances: storage, care, scan),
/// plus the 60 s volume poll that feeds the low-space alert. Read-only: nothing here selects, cleans or deletes.
@MainActor @Observable
final class MenuBarModel {
    let storage: StorageModel
    let care: CareScanModel
    let scan: ScanViewModel
    let settings: SettingsModel

    /// The "Next Care Scan" row stays hidden until scheduled scans (#23) exist.
    var nextScheduledScan: Date?

    @ObservationIgnored private let notifier: any LowSpaceNotifying
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let pollInterval: Duration
    @ObservationIgnored private var monitor: LowSpaceMonitor
    @ObservationIgnored private var lastThreshold: Int?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var sleeping = false
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init(storage: StorageModel, care: CareScanModel, scan: ScanViewModel, settings: SettingsModel,
         notifier: any LowSpaceNotifying, defaults: UserDefaults = .standard, pollInterval: Duration = .seconds(60)) {
        self.storage = storage
        self.care = care
        self.scan = scan
        self.settings = settings
        self.notifier = notifier
        self.defaults = defaults
        self.pollInterval = pollInterval
        self.monitor = LowSpaceMonitor.load(from: defaults)
    }

    // MARK: Derived (pure)

    var freeBytes: Int64? { storage.freeBytes }
    var usedFraction: Double? { storage.usedFraction }
    var volumeName: String { storage.volumeName }

    var freeFraction: Double? {
        guard let free = freeBytes, let total = storage.totalBytes, total > 0 else { return nil }
        return min(1, max(0, Double(free) / Double(total)))
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

    var labelAccessibility: String {
        MenuBarCopy.labelA11y(freeBytes.map { Formatting.bytes($0) } ?? "—")
    }

    /// `MenuBarExtra(isInserted:)` reads and writes the persisted setting.
    static func insertedBinding(_ settings: SettingsModel) -> Binding<Bool> {
        Binding(get: { settings.settings.showMenuBarItem }, set: { settings.setShowMenuBarItem($0) })
    }

    // MARK: Poll

    /// One poll step: refresh the volume (coalesced to ≥ 60 s by `StorageModel`), then feed the alert.
    func tick() async {
        storage.refresh()
        await storage.settle()
        await evaluateLowSpace()
    }

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
        if fire { await notifier.notify(freeBytes: free, percent: percent) }
    }

    /// Polls while the app runs, never faster than `pollInterval`, and pauses while the Mac sleeps.
    func start() {
        guard pollTask == nil else { return }
        let center = NSWorkspace.shared.notificationCenter
        observers = [
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.sleeping = true }
            },
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.sleeping = false }
            },
        ]
        let interval = pollInterval
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                if let self, !self.sleeping { await self.tick() }
                try? await Task.sleep(for: interval)
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        for o in observers { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        observers = []
    }
}
