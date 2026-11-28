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

    private func rig(_ f: ScanFrequency, power: FakePower = FakePower(), model: SettingsModel? = nil,
                     isBusy: @escaping @MainActor () -> Bool = { false }, runner customRunner: (any ScheduledScanRunning)? = nil) -> Rig {
        let runner = FakeRunner(), notifier = SpyNotifier(), ticker = FakeTicker()
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let c = ScheduledScanController(settings: model ?? settings(f), runner: customRunner ?? runner, notifier: notifier, ticker: ticker, power: power,
                                        clock: { [unowned self] in now }, calendar: cal, defaults: defaults,
                                        launchCheckDelay: nil, isBusy: isBusy)
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

    func testDueRunAlertsOnce() async {
        let r = rig(.daily)
        defaults.set(now.addingTimeInterval(-90_000), forKey: ScheduledScanController.lastRunKey)
        r.runner.outcome = outcome(safeGB: 8)
        r.controller.start()
        await r.ticker.handler?()
        XCTAssertEqual(r.runner.calls, 1)
        XCTAssertEqual(r.notifier.scheduled, [.safeToFree(bytes: 8 * ScheduledAlertPolicy.gigabyte)])
        XCTAssertEqual(r.controller.lastRunAt, now)
        await r.ticker.handler?()   // next period not reached
        XCTAssertEqual(r.runner.calls, 1)
    }

    func testReEnablingRestartsTheClock() async {
        let model = settings(.daily)
        let r = rig(.daily, model: model)
        defaults.set(now.addingTimeInterval(-90_000), forKey: ScheduledScanController.lastRunKey)   // stale
        r.controller.start()
        model.setScanFrequency(.off)
        await r.controller.frequencyChanged()
        model.setScanFrequency(.daily)
        await r.controller.frequencyChanged()
        XCTAssertEqual(r.controller.lastRunAt, now)
        await r.ticker.handler?()
        XCTAssertEqual(r.runner.calls, 0)
    }

    func testFutureLastRunDoesNotStallTheSchedule() async {
        let r = rig(.daily)
        defaults.set(now.addingTimeInterval(86_400 * 30), forKey: ScheduledScanController.lastRunKey)
        XCTAssertEqual(r.controller.nextRun, now.addingTimeInterval(86_400))
    }

    // MARK: Read-only through the real CareScanModel (B1, B2, B3)

    /// A real `CareScanModel` + `ScanViewModel`, a `SelectionModel` synced to the scan generation like `RootView`, and a
    /// `CleanupCoordinator` over a spy engine, all wired into the controller exactly like `AppModels`.
    private struct Real {
        var care: CareRig
        var selection: SelectionModel
        var cleanup: CleanupCoordinator
        var engine: FakeCleanupEngine
        var item: ScanItem
        var r: Rig
    }

    private func real(selected: Bool) -> Real {
        let care = CareRig()
        let selection = SelectionModel()
        let engine = FakeCleanupEngine()
        let cleanup = CleanupCoordinator(holder: CleanupEngineHolder(engine: engine))
        let item = ItemFixtures.item("cache1", tier: .safe, size: 500)
        selection.syncScanGeneration(care.scan.scanGeneration)
        if selected { selection.setSelected(item, true) }
        let r = rig(.daily, isBusy: { cleanup.isPresented || !selection.selectedIDs.isEmpty }, runner: care.model)
        defaults.set(now.addingTimeInterval(-90_000), forKey: ScheduledScanController.lastRunKey)
        r.controller.start()
        return Real(care: care, selection: selection, cleanup: cleanup, engine: engine, item: item, r: r)
    }

    func testScheduledRunNeverClearsTheUsersSelection() async {
        let x = real(selected: true)
        await x.r.ticker.handler?()
        x.selection.syncScanGeneration(x.care.scan.scanGeneration)   // what RootView does on every generation change
        let scans = await x.care.coordinator.scanCalls
        XCTAssertEqual(scans, 0, "deferred: the user has items ticked")
        XCTAssertEqual(x.selection.selectedIDs, [x.item.id])
        let plans = await x.engine.issuedPlans, executed = await x.engine.executedPlans
        XCTAssertTrue(plans.isEmpty && executed.isEmpty)
    }

    func testScheduledRunDefersWhileACleanupIsOpen() async {
        let x = real(selected: false)
        x.cleanup.review([x.item]) { _ in }
        await x.care.waitUntil { x.cleanup.isPresented }
        let plansBefore = await x.engine.issuedPlans.count
        await x.r.ticker.handler?()
        let scans = await x.care.coordinator.scanCalls
        XCTAssertEqual(scans, 0)
        let plansAfter = await x.engine.issuedPlans.count, executed = await x.engine.executedPlans
        XCTAssertEqual(plansAfter, plansBefore)
        XCTAssertTrue(executed.isEmpty)
    }

    func testScheduledRunWithNothingTickedRunsAndNeverPlansOrExecutes() async {
        let x = real(selected: false)
        let tick = Task { await x.r.ticker.handler?() }
        await x.care.waitUntil { await x.care.coordinator.isScanning }
        await x.care.coordinator.send(CareFix.started(), .finished(CareFix.report(safe: 7_000_000_000)))
        await tick.value
        XCTAssertEqual(x.care.model.phase, .results)
        XCTAssertEqual(x.r.notifier.scheduled.count, 1)
        x.selection.syncScanGeneration(x.care.scan.scanGeneration)
        XCTAssertTrue(x.selection.selectedIDs.isEmpty)
        let plans = await x.engine.issuedPlans, executed = await x.engine.executedPlans
        XCTAssertTrue(plans.isEmpty && executed.isEmpty)
        XCTAssertFalse(x.cleanup.isPresented)
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

    // MARK: Spy filesystem: a scheduled run on a temp home changes nothing

    private struct Stat: Equatable { var ino: UInt64; var size: Int64; var mtime: Int; var mtimeNs: Int; var mode: UInt16 }

    private func snapshot(_ root: String) -> [String: Stat] {
        var out: [String: Stat] = [:]
        let e = FileManager.default.enumerator(atPath: root)
        while let rel = e?.nextObject() as? String {
            var st = stat()
            if lstat(root + "/" + rel, &st) == 0 {
                out[rel] = Stat(ino: UInt64(st.st_ino), size: Int64(st.st_size), mtime: st.st_mtimespec.tv_sec,
                                mtimeNs: st.st_mtimespec.tv_nsec, mode: st.st_mode)
            }
        }
        return out
    }

    func testRealScheduledRunLeavesTheTempHomeUntouched() async throws {
        let home = dir.appendingPathComponent("home").path
        let fm = FileManager.default
        for d in [".Trash", ".claude/projects/-ADKQA", "Library/Caches/com.example.app", "Downloads"] {
            try fm.createDirectory(atPath: home + "/" + d, withIntermediateDirectories: true)
        }
        let old = Date(timeIntervalSince1970: 1_500_000_000)
        for f in [".claude/projects/-ADKQA/a.jsonl", "Library/Caches/com.example.app/blob", "Downloads/big.bin"] {
            fm.createFile(atPath: home + "/" + f, contents: Data(repeating: 7, count: 4096), attributes: [.modificationDate: old])
        }
        let env = PathEnvironment(home: home, temporaryDirectory: dir.path + "/tmp")
        // Only the Claude Code rules, copied to a temp dir: the scan stays inside the temp home (never /Library, /var).
        let rules = dir.appendingPathComponent("rules")
        try fm.createDirectory(at: rules, withIntermediateDirectories: true)
        try fm.copyItem(at: CoreResources.rulesDirectoryURL!.appendingPathComponent("claude-code.json"),
                        to: rules.appendingPathComponent("claude-code.json"))
        let before = snapshot(home)
        XCTAssertNotNil(before[".Trash"])

        let coordinator = CareScanCoordinator(
            stages: [CareStages.rules { try ScanEngine.makeDefault(environment: env, bundledRulesDirectory: rules) }], history: nil, scopeFingerprint: "t22")
        let care = CareRig()
        let model = CareScanModel(makeCoordinator: { _ in coordinator }, scan: care.scan, index: care.index,
                                  duplicates: { nil }, largeOld: { nil }, announce: { _ in })
        let r = rig(.daily, runner: model)
        defaults.set(now.addingTimeInterval(-90_000), forKey: ScheduledScanController.lastRunKey)
        r.controller.start()
        await r.ticker.handler?()

        XCTAssertEqual(model.phase, .results, "the scheduled run really ran")
        let after = snapshot(home)
        XCTAssertEqual(after, before, "a scheduled run must change nothing on disk")
        XCTAssertNil(after[".Trash/" + (before.keys.first { $0.hasPrefix(".Trash/") } ?? "x")])
        XCTAssertNil(after["Library/Application Support/AIDiskKeeper/audit.jsonl"])
    }
}

