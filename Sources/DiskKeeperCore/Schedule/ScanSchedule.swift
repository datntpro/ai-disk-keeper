import Foundation

/// How often the scheduled Care Scan runs. Off by default (T22).
public enum ScanFrequency: String, Codable, Sendable, CaseIterable {
    case off, daily, weekly
}

/// What the machine is doing right now; the scheduler only runs on a quiet, powered machine.
public struct PowerState: Sendable, Equatable {
    public var onBattery: Bool
    public var lowPowerMode: Bool
    /// A user-started scan or cleanup is in flight.
    public var userScanRunning: Bool

    public init(onBattery: Bool = false, lowPowerMode: Bool = false, userScanRunning: Bool = false) {
        self.onBattery = onBattery
        self.lowPowerMode = lowPowerMode
        self.userScanRunning = userScanRunning
    }
}

public enum ScheduleDecision: Sendable, Equatable {
    case run
    case notDue
    case `defer`(DeferReason)

    public enum DeferReason: Sendable, Equatable { case onBattery, lowPower, busy }
}

/// Pure schedule arithmetic. A run missed while the Mac slept fires once at the next check; never several.
public enum ScanSchedulePolicy {
    /// The next due time: one calendar day / week after the last run, at the same moment. With no previous run the
    /// first scan is due one period after the schedule is turned on (`now`), so turning it on never scans at once.
    public static func nextRun(after last: Date?, frequency: ScanFrequency, now: Date, calendar: Calendar) -> Date? {
        let component: Calendar.Component
        switch frequency {
        case .off: return nil
        case .daily: component = .day
        case .weekly: component = .weekOfYear
        }
        // A last run in the future (the clock was set ahead, then corrected) must not stall the schedule.
        let base = last.map { min($0, now) } ?? now
        return calendar.date(byAdding: component, value: 1, to: base)
    }

    public static func shouldRun(now: Date, next: Date?, power: PowerState, skipOnBattery: Bool = true) -> ScheduleDecision {
        guard let next, now >= next else { return .notDue }
        if power.userScanRunning { return .defer(.busy) }
        // Both power gates follow the one toggle ("Skip on battery and in Low Power Mode").
        if skipOnBattery && power.lowPowerMode { return .defer(.lowPower) }
        if skipOnBattery && power.onBattery { return .defer(.onBattery) }
        return .run
    }
}

public enum ScheduledAlert: Sendable, Equatable {
    case safeToFree(bytes: Int64)
    case aiToolsGrew(bytes: Int64)
}

/// When a scheduled run is worth a notification (P9). At most one alert per run: Safe wins over growth.
public enum ScheduledAlertPolicy {
    public static let gigabyte: Int64 = 1_000_000_000

    public static func alert(totals: CareTotals, growth: CareGrowth?, safeThreshold: Int64, growthThreshold: Int64) -> ScheduledAlert? {
        if safeThreshold > 0, totals.safeBytes >= safeThreshold { return .safeToFree(bytes: totals.safeBytes) }
        if growthThreshold > 0, let growth, growth.aiToolsDelta >= growthThreshold { return .aiToolsGrew(bytes: growth.aiToolsDelta) }
        return nil
    }
}
