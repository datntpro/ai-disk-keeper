import XCTest
@testable import DiskKeeperCore

final class ScanSchedulePolicyTests: XCTestCase {
    private func cal(_ tz: String) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: tz)!
        return c
    }
    private func date(_ s: String, _ tz: String = "UTC") -> Date {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(identifier: tz)
        return f.date(from: s)!
    }

    func testOffHasNoNextRun() {
        XCTAssertNil(ScanSchedulePolicy.nextRun(after: Date(), frequency: .off, now: Date(), calendar: cal("UTC")))
    }

    func testDailyAndWeekly() {
        let c = cal("UTC")
        let last = date("2026-03-01T09:00:00Z")
        XCTAssertEqual(ScanSchedulePolicy.nextRun(after: last, frequency: .daily, now: last, calendar: c), date("2026-03-02T09:00:00Z"))
        XCTAssertEqual(ScanSchedulePolicy.nextRun(after: last, frequency: .weekly, now: last, calendar: c), date("2026-03-08T09:00:00Z"))
    }

    func testNoPreviousRunStartsOnePeriodAfterNow() {
        let now = date("2026-03-01T09:00:00Z")
        XCTAssertEqual(ScanSchedulePolicy.nextRun(after: nil, frequency: .daily, now: now, calendar: cal("UTC")), date("2026-03-02T09:00:00Z"))
    }

    func testDaylightSavingKeepsWallClockTime() {
        let c = cal("America/New_York")   // spring forward 2026-03-08
        let last = date("2026-03-07T09:00:00-05:00", "America/New_York")
        let next = ScanSchedulePolicy.nextRun(after: last, frequency: .daily, now: last, calendar: c)!
        XCTAssertEqual(c.component(.hour, from: next), 9)
        XCTAssertEqual(c.component(.day, from: next), 8)
    }

    func testTimeZoneChangeStillAddsACalendarPeriod() {
        let last = date("2026-03-01T09:00:00Z")
        let tokyo = ScanSchedulePolicy.nextRun(after: last, frequency: .daily, now: last, calendar: cal("Asia/Tokyo"))!
        XCTAssertEqual(tokyo.timeIntervalSince(last), 86_400, accuracy: 1)
    }

    func testLastRunInTheFutureDoesNotStall() {
        let now = date("2026-03-01T09:00:00Z")
        let future = date("2026-06-01T09:00:00Z")
        XCTAssertEqual(ScanSchedulePolicy.nextRun(after: future, frequency: .daily, now: now, calendar: cal("UTC")), date("2026-03-02T09:00:00Z"))
    }

    func testToggleOffIgnoresPowerGates() {
        let now = Date(), due = now.addingTimeInterval(-1)
        XCTAssertEqual(ScanSchedulePolicy.shouldRun(now: now, next: due, power: PowerState(lowPowerMode: true), skipOnBattery: false), .run)
    }

    func testNotDueBeforeNextAndNilNext() {
        let now = Date()
        XCTAssertEqual(ScanSchedulePolicy.shouldRun(now: now, next: now.addingTimeInterval(60), power: PowerState()), .notDue)
        XCTAssertEqual(ScanSchedulePolicy.shouldRun(now: now, next: nil, power: PowerState()), .notDue)
    }

    func testMissedRunFiresOnce() {
        let now = Date()
        XCTAssertEqual(ScanSchedulePolicy.shouldRun(now: now, next: now.addingTimeInterval(-86_400 * 5), power: PowerState()), .run)
    }

    func testDefers() {
        let now = Date(), due = now.addingTimeInterval(-1)
        XCTAssertEqual(ScanSchedulePolicy.shouldRun(now: now, next: due, power: PowerState(onBattery: true)), .defer(.onBattery))
        XCTAssertEqual(ScanSchedulePolicy.shouldRun(now: now, next: due, power: PowerState(lowPowerMode: true)), .defer(.lowPower))
        XCTAssertEqual(ScanSchedulePolicy.shouldRun(now: now, next: due, power: PowerState(userScanRunning: true)), .defer(.busy))
        XCTAssertEqual(ScanSchedulePolicy.shouldRun(now: now, next: due, power: PowerState(onBattery: true), skipOnBattery: false), .run)
    }
}

final class ScheduledAlertPolicyTests: XCTestCase {
    private let gb = ScheduledAlertPolicy.gigabyte
    private func totals(safe: Int64) -> CareTotals { var t = CareTotals(); t.safeBytes = safe; return t }
    private func growth(_ d: Int64) -> CareGrowth { CareGrowth(since: Date(), aiToolsDelta: d, perTool: [:]) }

    func testSafeThreshold() {
        XCTAssertEqual(ScheduledAlertPolicy.alert(totals: totals(safe: 5 * gb), growth: nil, safeThreshold: 5 * gb, growthThreshold: 2 * gb), .safeToFree(bytes: 5 * gb))
        XCTAssertNil(ScheduledAlertPolicy.alert(totals: totals(safe: 5 * gb - 1), growth: nil, safeThreshold: 5 * gb, growthThreshold: 2 * gb))
    }

    func testGrowthThresholdAndNilGrowthIgnored() {
        XCTAssertEqual(ScheduledAlertPolicy.alert(totals: totals(safe: 0), growth: growth(3 * gb), safeThreshold: 5 * gb, growthThreshold: 2 * gb), .aiToolsGrew(bytes: 3 * gb))
        XCTAssertNil(ScheduledAlertPolicy.alert(totals: totals(safe: 0), growth: nil, safeThreshold: 5 * gb, growthThreshold: 2 * gb))
        XCTAssertNil(ScheduledAlertPolicy.alert(totals: totals(safe: 0), growth: growth(-9 * gb), safeThreshold: 5 * gb, growthThreshold: 2 * gb))
    }

    func testAtMostOneAlertSafeWins() {
        XCTAssertEqual(ScheduledAlertPolicy.alert(totals: totals(safe: 9 * gb), growth: growth(9 * gb), safeThreshold: 5 * gb, growthThreshold: 2 * gb), .safeToFree(bytes: 9 * gb))
    }
}

final class AppSettingsScheduleTests: XCTestCase {
    func testDefaultsOldFileAndRoundTrip() throws {
        let old = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(old.scanFrequency, .off)
        XCTAssertEqual(old.scheduledSafeAlertGB, 5)
        XCTAssertEqual(old.scheduledGrowthAlertGB, 2)
        XCTAssertTrue(old.scheduledSkipOnBattery)
        var s = AppSettings.defaults
        s.scanFrequency = .weekly; s.scheduledSafeAlertGB = 9; s.scheduledGrowthAlertGB = 4; s.scheduledSkipOnBattery = false
        let back = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back, s)
    }

    func testBadValuesFallBack() throws {
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"scanFrequency":"hourly","scheduledSafeAlertGB":0}"#.utf8))
        XCTAssertEqual(s.scanFrequency, .off)
        XCTAssertEqual(s.scheduledSafeAlertGB, 1)
    }
}
