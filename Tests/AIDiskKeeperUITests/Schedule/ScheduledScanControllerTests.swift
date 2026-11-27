import DiskKeeperCore
import XCTest
@testable import AIDiskKeeperUI

@MainActor
private final class SpyNotifier: AppNotifying {
    var permissionRequests = 0
    var scheduled: [ScheduledAlert] = []
    func notify(freeBytes: Int64, percent: Int) async {}
    func requestPermission() async -> Bool { permissionRequests += 1; return true }
    func notifyScheduled(_ alert: ScheduledAlert) async { scheduled.append(alert) }
}

@MainActor
private final class FakeTicker: ScheduleTicking {
    var handler: (@MainActor () async -> Void)?
    var started = 0
    func start(_ handler: @escaping @MainActor () async -> Void) { self.handler = handler; started += 1 }
    func stop() { handler = nil }
}

private struct FakePower: PowerSourceReading {
    var onBattery = false
    var lowPower = false
    func read() -> (onBattery: Bool, lowPowerMode: Bool) { (onBattery, lowPower) }
}

@MainActor
private final class FakeRunner: ScheduledScanRunning {
    var isUserBusy = false
    var calls = 0
    var outcome: ScheduledScanOutcome?
    func startScheduled() async -> ScheduledScanOutcome? { calls += 1; return outcome }
}

@MainActor
final class ScheduledScanControllerTests: XCTestCase {
    private var dir: URL!
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("SchedCtl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        suiteName = "SchedCtl-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: dir)
    }

    private func settings(_ f: ScanFrequency) -> SettingsModel {
        let m = SettingsModel(store: SettingsStore(fileURL: dir.appendingPathComponent("s.json")),
                              environment: PathEnvironment(home: dir.path, temporaryDirectory: dir.path), probe: { .unknown })
        m.setScanFrequency(f)
        return m
    }

    private func outcome(safeGB: Int64) -> ScheduledScanOutcome {
        var t = CareTotals(); t.safeBytes = safeGB * ScheduledAlertPolicy.gigabyte
        return ScheduledScanOutcome(totals: t, growth: nil)
    }

    private struct Rig {
        var controller: ScheduledScanController
        var runner: FakeRunner
        var notifier: SpyNotifier
        var ticker: FakeTicker
    }

    private func rig(_ f: ScanFrequency, power: FakePower = FakePower(), model: SettingsModel? = nil) -> Rig {
        let runner = FakeRunner(), notifier = SpyNotifier(), ticker = FakeTicker()
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let c = ScheduledScanController(settings: model ?? settings(f), runner: runner, notifier: notifier, ticker: ticker, power: power,
                                        clock: { [unowned self] in now }, calendar: cal, defaults: defaults)
        return Rig(controller: c, runner: runner, notifier: notifier, ticker: ticker)
    }

    func testStartNeverAsksForPermissionAndNeverScans() {
        let r = rig(.daily)
        r.controller.start()
        XCTAssertEqual(r.notifier.permissionRequests, 0)
        XCTAssertEqual(r.runner.calls, 0)
        XCTAssertEqual(r.ticker.started, 1)
    }

    func testTurningOnAsksOnceAndStartsTheClock() async {
        let model = settings(.off)
        let r = rig(.off, model: model)
        r.controller.start()
        model.setScanFrequency(.daily)
        await r.controller.frequencyChanged()
        XCTAssertEqual(r.notifier.permissionRequests, 1)
        XCTAssertEqual(r.controller.lastRunAt, now)
        model.setScanFrequency(.weekly)
        await r.controller.frequencyChanged()
        XCTAssertEqual(r.notifier.permissionRequests, 1)
    }

    func testDueRunIsReadOnlyAndAlertsOnce() async {
        let engine = FakeCleanupEngine()
        let coordinator = CleanupCoordinator(holder: CleanupEngineHolder(engine: engine))
        let selection = SelectionModel()
        let r = rig(.daily)
        defaults.set(now.addingTimeInterval(-90_000), forKey: ScheduledScanController.lastRunKey)
        r.runner.outcome = outcome(safeGB: 8)
        await r.ticker.handler?()   // not started yet: nothing
        r.controller.start()
        await r.ticker.handler?()
        XCTAssertEqual(r.runner.calls, 1)
        XCTAssertEqual(r.notifier.scheduled, [.safeToFree(bytes: 8 * ScheduledAlertPolicy.gigabyte)])
        XCTAssertEqual(r.controller.lastRunAt, now)
        XCTAssertTrue(selection.selectedIDs.isEmpty)
        XCTAssertFalse(coordinator.isPresented)
        let plans = await engine.issuedPlans, executed = await engine.executedPlans
        XCTAssertTrue(plans.isEmpty && executed.isEmpty)
        await r.ticker.handler?()   // next period not reached
        XCTAssertEqual(r.runner.calls, 1)
    }

    func testBelowThresholdPostsNothing() async {
        let r = rig(.daily)
        defaults.set(now.addingTimeInterval(-90_000), forKey: ScheduledScanController.lastRunKey)
        r.runner.outcome = outcome(safeGB: 1)
        r.controller.start()
        await r.ticker.handler?()
        XCTAssertEqual(r.runner.calls, 1)
        XCTAssertTrue(r.notifier.scheduled.isEmpty)
    }

    func testDefersOnBatteryLowPowerAndUserScan() async {
        for (power, busy) in [(FakePower(onBattery: true), false), (FakePower(lowPower: true), false), (FakePower(), true)] {
            let r = rig(.daily, power: power)
            defaults.set(now.addingTimeInterval(-90_000), forKey: ScheduledScanController.lastRunKey)
            r.runner.isUserBusy = busy
            r.controller.start()
            await r.ticker.handler?()
            XCTAssertEqual(r.runner.calls, 0)
        }
    }

    func testOffNeverRuns() async {
        let r = rig(.off)
        defaults.set(Date(timeIntervalSince1970: 0), forKey: ScheduledScanController.lastRunKey)
        r.controller.start()
        await r.ticker.handler?()
        XCTAssertEqual(r.runner.calls, 0)
    }

    func testRealCareModelScheduledRunDoesNotTouchSelection() async {
        let care = CareRig()
        let selection = SelectionModel()
        let task = Task { await care.model.startScheduled() }
        await care.waitUntil { await care.coordinator.isScanning }
        await care.coordinator.send(CareFix.started(), .finished(CareFix.report(safe: 7)))
        let result = await task.value
        XCTAssertEqual(result?.totals.safeBytes, 7)
        XCTAssertTrue(selection.selectedIDs.isEmpty)
        XCTAssertEqual(care.model.phase, .results)
    }
}
