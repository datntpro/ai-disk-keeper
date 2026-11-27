import DiskKeeperCore
import Foundation
import Observation

struct ScheduledScanOutcome: Sendable {
    var totals: CareTotals
    var growth: CareGrowth?
}

/// The Care Scan as the scheduler sees it. `CareScanModel` is the real one; tests script it.
@MainActor
protocol ScheduledScanRunning: AnyObject {
    /// A user scan (rule or Care) is in flight.
    var isUserBusy: Bool { get }
    func startScheduled() async -> ScheduledScanOutcome?
}

/// Fires the periodic check; the live one is an `NSBackgroundActivityScheduler`.
@MainActor
protocol ScheduleTicking: AnyObject {
    func start(_ handler: @escaping @MainActor () async -> Void)
    func stop()
}

@MainActor
final class BackgroundActivityTicker: ScheduleTicking {
    static let identifier = "io.github.datntpro.aidiskkeeper.scheduledScan"
    private var activity: NSBackgroundActivityScheduler?

    func start(_ handler: @escaping @MainActor () async -> Void) {
        stop()
        let a = NSBackgroundActivityScheduler(identifier: Self.identifier)
        a.repeats = true
        a.interval = 3600
        a.tolerance = 900
        a.qualityOfService = .utility
        a.schedule { completion in
            Task { @MainActor in
                await handler()
                completion(.finished)
            }
        }
        activity = a
    }

    func stop() {
        activity?.invalidate()
        activity = nil
    }
}

/// Runs the Care Scan on a schedule and posts at most one alert per run. Read-only by construction: it holds no
/// cleanup engine and no selection, only the scan runner and the notifier.
@MainActor
final class ScheduledScanController {
    static let lastRunKey = "ADK.scheduledLastRun"

    private let settings: SettingsModel
    private let runner: any ScheduledScanRunning
    private let notifier: any AppNotifying
    private let ticker: any ScheduleTicking
    private let power: any PowerSourceReading
    private let clock: () -> Date
    private let calendar: Calendar
    private let defaults: UserDefaults
    private let onNextRun: (Date?) -> Void
    private var running = false
    private var lastFrequency: ScanFrequency

    init(settings: SettingsModel, runner: any ScheduledScanRunning, notifier: any AppNotifying,
         ticker: any ScheduleTicking = BackgroundActivityTicker(), power: any PowerSourceReading = LivePowerSource(),
         clock: @escaping () -> Date = Date.init, calendar: Calendar = .current, defaults: UserDefaults = .standard,
         onNextRun: @escaping (Date?) -> Void = { _ in }) {
        self.settings = settings
        self.runner = runner
        self.notifier = notifier
        self.ticker = ticker
        self.power = power
        self.clock = clock
        self.calendar = calendar
        self.defaults = defaults
        self.onNextRun = onNextRun
        self.lastFrequency = settings.settings.scanFrequency
    }

    var lastRunAt: Date? {
        get { defaults.object(forKey: Self.lastRunKey) as? Date }
        set { defaults.set(newValue, forKey: Self.lastRunKey) }
    }

    var nextRun: Date? {
        ScanSchedulePolicy.nextRun(after: lastRunAt, frequency: settings.settings.scanFrequency, now: clock(), calendar: calendar)
    }

    /// Starts the periodic check and follows the frequency setting. Asks for no permission here.
    func start() {
        ticker.start { [weak self] in await self?.check() }
        observe()
        onNextRun(nextRun)
    }

    func stop() { ticker.stop() }

    private func observe() {
        withObservationTracking {
            _ = settings.settings.scanFrequency
        } onChange: { [weak self] in
            Task { @MainActor in
                await self?.frequencyChanged()
                self?.observe()
            }
        }
    }

    /// Turning the schedule on asks for notification permission (once, by the notifier) and starts the clock now.
    func frequencyChanged() async {
        let now = settings.settings.scanFrequency
        let was = lastFrequency
        lastFrequency = now
        if now == .off {
            onNextRun(nil)
            return
        }
        if was == .off {
            if lastRunAt == nil { lastRunAt = clock() }
            _ = await notifier.requestPermission()
        }
        onNextRun(nextRun)
    }

    /// One periodic check. Runs the scan at most once per call, and a missed period still means one run.
    func check() async {
        guard !running else { return }
        let s = settings.settings
        let state = power.read()
        let decision = ScanSchedulePolicy.shouldRun(
            now: clock(), next: nextRun,
            power: PowerState(onBattery: state.onBattery, lowPowerMode: state.lowPowerMode, userScanRunning: runner.isUserBusy),
            skipOnBattery: s.scheduledSkipOnBattery)
        guard decision == .run else { return }
        running = true
        defer { running = false }
        lastRunAt = clock()   // before the scan: a crash or a cancelled run never repeats in a loop
        let outcome = await runner.startScheduled()
        onNextRun(nextRun)
        guard let outcome else { return }
        let gb = ScheduledAlertPolicy.gigabyte
        if let alert = ScheduledAlertPolicy.alert(totals: outcome.totals, growth: outcome.growth,
                                                  safeThreshold: Int64(s.scheduledSafeAlertGB) * gb,
                                                  growthThreshold: Int64(s.scheduledGrowthAlertGB) * gb) {
            await notifier.notifyScheduled(alert)
        }
    }
}

extension CareScanModel: ScheduledScanRunning {
    var isUserBusy: Bool { isBusy || scan.isScanning }
}
