import AppKit
import DiskKeeperCore
import Foundation
import Observation

/// Pure schedule state: what is due at virtual time `now`, and how long until something is. Tested without a clock.
struct MonitorPlanner {
    struct Due: Equatable {
        var metrics: Set<MetricID> = []
        var perCore = false
        var topProcesses = false
        var disk = false
        var isEmpty: Bool { metrics.isEmpty && !disk }
    }

    static let slack: Duration = .milliseconds(50)
    private var lastMetrics: Duration?
    private var lastDisk: Duration?
    private var metricTicks = 0

    /// A sample right now for the current demand (popover opened, wake, settings change).
    mutating func sampleMetricsNow() { lastMetrics = nil }
    mutating func reset() { lastMetrics = nil; lastDisk = nil; metricTicks = 0 }

    mutating func due(at now: Duration, plan: SamplePlan) -> Due {
        var d = Due()
        if let every = plan.metricsInterval, !plan.metrics.isEmpty, lastMetrics.map({ now - $0 >= every - Self.slack }) ?? true {
            lastMetrics = now
            d.metrics = plan.metrics
            d.perCore = plan.perCore
            if plan.topProcesses {
                d.topProcesses = metricTicks % 2 == 0   // every 2nd tick (4 s in the popover)
                metricTicks += 1
            } else {
                metricTicks = 0
            }
        }
        if let every = plan.diskInterval, lastDisk.map({ now - $0 >= every - Self.slack }) ?? true {
            lastDisk = now
            d.disk = true
        }
        return d
    }

    /// Time until the next due item; nil when nothing is scheduled (the Mac sleeps).
    func delay(at now: Duration, plan: SamplePlan) -> Duration? {
        var next: Duration?
        func consider(_ every: Duration?, _ last: Duration?) {
            guard let every else { return }
            let at = last.map { $0 + every } ?? now
            next = min(next ?? at, at)
        }
        consider(plan.metrics.isEmpty ? nil : plan.metricsInterval, lastMetrics)
        consider(plan.diskInterval, lastDisk)
        return next.map { max($0 - now, .zero) }
    }
}

/// The one timer. One `Task` loop sleeps until the next due sample; a demand change cancels the sleep (not the loop)
/// and the loop plans again. Each wake runs the due samplers in one off-main task and publishes one snapshot.
@MainActor
final class MonitorScheduler {
    let monitor: SystemMonitorModel
    private let menuBar: MenuBarModel
    private let settings: SettingsModel
    private let hostLoad: DiskActivityModel?
    private let sampler: SystemSampler
    private let clock: () -> Duration
    private let sleeper: (Duration) async -> Void
    private var planner = MonitorPlanner()
    private var lastPlan: SamplePlan?
    private var loop: Task<Void, Never>?
    private var sleeping: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private(set) var loopsStarted = 0
    /// When each metric was last read and at what cadence, to spot a gap that would make the next delta meaningless.
    private var lastSampled: [MetricID: (at: Duration, interval: Duration)] = [:]

    static let idleSleep: Duration = .seconds(3600)

    init(monitor: SystemMonitorModel, menuBar: MenuBarModel, settings: SettingsModel, sampler: SystemSampler = SystemSampler(), hostLoad: DiskActivityModel? = nil,
         clock: @escaping () -> Duration = MonitorScheduler.liveClock,
         sleeper: @escaping (Duration) async -> Void = MonitorScheduler.liveSleep) {
        self.monitor = monitor
        self.menuBar = menuBar
        self.settings = settings
        self.sampler = sampler
        self.hostLoad = hostLoad
        self.clock = clock
        self.sleeper = sleeper
    }

    static let liveClock: () -> Duration = {
        let base = ContinuousClock.now
        return { ContinuousClock.now - base }
    }()

    /// Tolerance lets macOS coalesce wakeups.
    static func liveSleep(_ d: Duration) async {
        try? await Task.sleep(for: d, tolerance: d / 10)
    }

    var isRunning: Bool { loop != nil }

    func start(observeSystem: Bool = true) {
        guard loop == nil else { return }
        loopsStarted += 1
        monitor.onDemandChange = { [weak self] in self?.demandChanged() }
        if observeSystem { observeSystemEvents() }
        observeSettings()
        loop = Task { [weak self] in await self?.run() }
    }

    func stop() {
        loop?.cancel(); sleeping?.cancel()
        loop = nil; sleeping = nil
        monitor.onDemandChange = nil
        hostLoad?.stop()
        let center = NSWorkspace.shared.notificationCenter
        for o in observers { center.removeObserver(o) }
        observers = []
    }

    /// Demand changed (popover, settings, sleep/wake): plan again by restarting the sleep, never by adding a timer.
    func demandChanged() {
        let plan = SamplingPolicy.plan(monitor.demand)
        if plan != lastPlan, !plan.metrics.isEmpty { planner.sampleMetricsNow() }
        monitor.refreshLabel()
        // Host load (disk I/O per worktree) runs only while the popover is open, at its own 5 s cadence, never asleep.
        // The Disk Activity screen asks for it by itself. There is no background sampling.
        hostLoad?.setPopoverOpen(monitor.popoverOpen && !monitor.systemAsleep && !monitor.displayAsleep)
        hostLoad?.setSuspended(monitor.systemAsleep || monitor.displayAsleep)
        sleeping?.cancel()
    }

    private func run() async {
        while !Task.isCancelled {
            await tick()
            let delay = nextDelay()
            let task = Task { [sleeper] in await sleeper(delay) }
            sleeping = task
            await task.value
        }
    }

    /// How long the loop sleeps after a tick (an hour when nothing is scheduled, e.g. while the Mac sleeps).
    func nextDelay() -> Duration {
        planner.delay(at: clock(), plan: SamplingPolicy.plan(monitor.demand)) ?? Self.idleSleep
    }

    /// One wake: decide what is due, run it, publish.
    func tick() async {
        closePopoverIfHidden()
        let plan = SamplingPolicy.plan(monitor.demand)
        lastPlan = plan
        let due = planner.due(at: clock(), plan: plan)
        guard !due.isEmpty else { return }
        if due.disk { await menuBar.tick() }
        if !due.metrics.isEmpty {
            let t = clock()
            let stale = Self.staleMetrics(due.metrics, last: lastSampled, now: t)
            if !stale.isEmpty { monitor.markStale() }
            let snapshot = await sampler.sample(metrics: due.metrics, perCore: due.perCore, topProcesses: due.topProcesses, discarding: stale)
            for metric in due.metrics { lastSampled[metric] = (t, plan.metricsInterval ?? Self.idleSleep) }
            monitor.apply(snapshot)
        } else {
            monitor.refreshLabel()
        }
    }

    /// Metrics whose previous read is older than twice the cadence it was read at (after an idle gap, a closed
    /// popover, a hidden item): their first delta would average the whole gap, so it is dropped.
    static func staleMetrics(_ metrics: Set<MetricID>, last: [MetricID: (at: Duration, interval: Duration)], now: Duration) -> Set<MetricID> {
        Set(metrics.filter { m in last[m].map { now - $0.at > $0.interval * 2 + MonitorPlanner.slack } ?? false })
    }

    /// Safety net: `.onDisappear` can be missed by a menu bar window, so a hidden window closes the popover demand.
    private func closePopoverIfHidden() {
        if monitor.popoverOpen, let w = monitor.popoverWindow, !w.isVisible { monitor.setPopoverOpen(false) }
    }

    // MARK: Observers

    private func observeSystemEvents() {
        let center = NSWorkspace.shared.notificationCenter
        func add(_ name: Notification.Name, _ handler: @escaping @MainActor @Sendable (MonitorScheduler) -> Void) -> NSObjectProtocol {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if let self { handler(self) } }
            }
        }
        observers = [
            add(NSWorkspace.willSleepNotification) { $0.monitor.setSystemAsleep(true) },
            add(NSWorkspace.didWakeNotification) { $0.wake { $0.monitor.setSystemAsleep(false) } },
            add(NSWorkspace.screensDidSleepNotification) { $0.monitor.setDisplayAsleep(true) },
            add(NSWorkspace.screensDidWakeNotification) { $0.wake { $0.monitor.setDisplayAsleep(false) } },
        ]
    }

    /// After a wake the old counters and history are stale: sample once at once, then resume.
    func wake(_ change: (MonitorScheduler) -> Void) {
        change(self)
        planner.reset()
        lastSampled = [:]
        monitor.markStale()
        demandChanged()
    }

    private func observeSettings() {
        withObservationTracking { _ = settings.settings } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.isRunning else { return }
                self.demandChanged()
                self.observeSettings()
            }
        }
    }
}
