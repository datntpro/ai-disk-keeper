import DiskKeeperCore
import Foundation
import Observation

/// The latest host-load snapshot and a few minutes of whole-disk history for the sparkline. It never samples by
/// itself outside demand: the loop runs only while the popover or the Disk Activity screen is visible (every 5 s,
/// the floor), and a closed popover does no work at all.
@MainActor @Observable
final class DiskActivityModel {
    static let interval: Duration = .seconds(5)
    static let historyWindow: Double = 300

    private(set) var snapshot: HostLoadSnapshot?
    private(set) var writeHistory = MetricHistory(capacity: 90, maxAge: DiskActivityModel.historyWindow)
    private(set) var readHistory = MetricHistory(capacity: 90, maxAge: DiskActivityModel.historyWindow)
    private(set) var isRunning = false

    @ObservationIgnored private let sampler: HostLoadSampler
    @ObservationIgnored private let sleeper: @Sendable (Duration) async -> Void
    @ObservationIgnored private let now: () -> Double
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var popoverOpen = false
    @ObservationIgnored private var moduleVisible = false
    @ObservationIgnored private var suspended = false

    init(sampler: HostLoadSampler, now: @escaping () -> Double = SystemMonitorModel.defaultClock,
         sleeper: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0, tolerance: $0 / 5) }) {
        self.sampler = sampler
        self.now = now
        self.sleeper = sleeper
    }

    var wanted: Bool { (popoverOpen || moduleVisible) && !suspended }

    func setPopoverOpen(_ open: Bool) { popoverOpen = open; update() }
    func setModuleVisible(_ visible: Bool) { moduleVisible = visible; update() }
    /// Display or system asleep: no sampling.
    func setSuspended(_ value: Bool) { suspended = value; update() }
    func stop() { popoverOpen = false; moduleVisible = false; update() }

    private func update() {
        if wanted, loop == nil {
            isRunning = true
            loop = Task { [weak self] in await self?.run() }
        } else if !wanted, let running = loop {
            running.cancel()
            loop = nil
            isRunning = false
        }
    }

    private func run() async {
        while !Task.isCancelled {
            await tick()
            await sleeper(Self.interval)
        }
    }

    func tick() async {
        let snap = await sampler.tick()
        guard !Task.isCancelled else { return }
        apply(snap)
    }

    func apply(_ snap: HostLoadSnapshot) {
        snapshot = snap
        if let disk = snap.disk {
            let t = now()
            writeHistory.append(time: t, value: disk.writeBytesPerSec)
            readHistory.append(time: t, value: disk.readBytesPerSec)
        }
    }

    /// The popover's mini list: the three worktrees writing the most, ignoring near-idle rows.
    var topWorktrees: [WorktreeIO] {
        (snapshot?.byWorktree ?? []).filter { $0.writeBytesPerSec >= 100_000 }.prefix(3).map { $0 }
    }
}
