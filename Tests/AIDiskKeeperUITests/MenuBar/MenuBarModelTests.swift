import DiskKeeperCore
import XCTest
@testable import AIDiskKeeperUI

@MainActor
final class FakeNotifier: LowSpaceNotifying {
    private(set) var calls: [(free: Int64, percent: Int)] = []
    func notify(freeBytes: Int64, percent: Int) async { calls.append((freeBytes, percent)) }
}

final class OverviewLoads: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func hit() { lock.lock(); n += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return n }
}

final class Steps: @unchecked Sendable {
    private let lock = NSLock()
    private var free: [Int64]
    private let total: Int64
    init(_ free: [Int64], total: Int64) { self.free = free; self.total = total }
    func next() -> VolumeCapacity? {
        lock.lock(); defer { lock.unlock() }
        let f = free.count > 1 ? free.removeFirst() : free[0]
        return VolumeCapacity(free: f, total: total)
    }
}

@MainActor
final class MenuBarModelTests: XCTestCase {
    private var dir: URL!
    private var suiteName = ""
    private var defaults: UserDefaults!
    private let env = PathEnvironment(home: "/Users/tester", temporaryDirectory: "/tmp")
    private let gb = StorageFix.gb

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("MenuBarModelTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        suiteName = "T47-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }
    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func settings() -> SettingsModel {
        SettingsModel(store: SettingsStore(fileURL: dir.appendingPathComponent("settings.json")), environment: env,
                      probe: { .notGranted })
    }

    /// Volume of 494 GB whose free space steps through `freePercents` on each poll (the last one repeats).
    /// `storage.loads` counts full overviews (Trash walk + tmutil): the poll must leave it at 0.
    private func rig(_ freePercents: [Double], settings: SettingsModel? = nil) -> (MenuBarModel, FakeNotifier, CareRig, SettingsModel) {
        let (model, notifier, care, s, _) = rigWithCounter(freePercents, settings: settings)
        return (model, notifier, care, s)
    }

    private func rigWithCounter(_ freePercents: [Double], settings: SettingsModel? = nil)
        -> (MenuBarModel, FakeNotifier, CareRig, SettingsModel, OverviewLoads) {
        let steps = Steps(freePercents.map { Int64($0 / 100 * 494 * Double(gb)) }, total: 494 * gb)
        let loads = OverviewLoads()
        let storage = StorageModel(load: { loads.hit(); return StorageFix.overview() }, minInterval: 0)
        let care = CareRig()
        let notifier = FakeNotifier()
        let s = settings ?? self.settings()
        let model = MenuBarModel(storage: storage, care: care.model, scan: care.scan, settings: s, notifier: notifier,
                                 defaults: defaults, probe: { steps.next() })
        return (model, notifier, care, s, loads)
    }

    func testPollNeverRunsTheFullOverview() async {
        let (model, _, _, _, loads) = rigWithCounter([50, 40, 30])
        for _ in 0..<3 { await model.tick() }
        XCTAssertEqual(loads.count, 0, "the 60 s poll must not walk the Trash or spawn tmutil")
        XCTAssertNotNil(model.freeBytes)
        XCTAssertEqual(Double(model.freeFraction ?? 0), 0.30, accuracy: 0.001)
    }

    func testPopoverOpenRefreshesTheFullOverview() async {
        let (model, _, _, _, loads) = rigWithCounter([50])
        model.popoverOpened()
        await model.storage.settle()
        XCTAssertEqual(loads.count, 1)
    }

    func testNotificationShowsCurrentFreePercentNotTheThreshold() async {
        let (model, notifier, _, _) = rig([7.9])
        await model.tick()
        XCTAssertEqual(notifier.calls.first?.percent, 8)
    }

    func testPollNotifiesOncePerCrossing() async {
        let (model, notifier, _, _) = rig([15, 9, 8, 9.5, 12.5, 9, 9])
        for _ in 0..<7 { await model.tick() }
        XCTAssertEqual(notifier.calls.count, 2)
        XCTAssertEqual(notifier.calls.first?.percent, 9)
    }

    func testNeverNotifiesWhenAlertDisabled() async {
        let s = settings()
        s.setLowSpaceAlertEnabled(false)
        let (model, notifier, _, _) = rig([5, 4, 3], settings: s)
        for _ in 0..<3 { await model.tick() }
        XCTAssertTrue(notifier.calls.isEmpty)
    }

    func testThresholdChangeDoesNotFireWhenAlreadyBelow() async {
        let s = settings()
        let (model, notifier, _, _) = rig([12, 12, 12], settings: s)
        await model.tick()
        XCTAssertTrue(notifier.calls.isEmpty)
        s.setLowSpaceThresholdPercent(15)   // 12 % is now below, but the user just moved the slider
        await model.tick()
        XCTAssertTrue(notifier.calls.isEmpty)
        s.setLowSpaceThresholdPercent(10)
        await model.tick()
        XCTAssertTrue(notifier.calls.isEmpty)
    }

    func testBeforeAnyScan() async {
        let (model, _, _, _) = rig([50])
        await model.tick()
        XCTAssertNil(model.safeBytes)
        XCTAssertNil(model.lastScanAt)
        XCTAssertNil(model.aiGrowth)
        XCTAssertTrue(model.topTools.isEmpty)
        XCTAssertNil(model.topSafeModule)
        XCTAssertNil(model.nextScheduledScan)
        XCTAssertNotNil(model.freeBytes)
        XCTAssertEqual(model.volumeName, "Macintosh HD")
    }

    func testDerivedValuesAfterAScan() async {
        let (model, _, rig, _) = rig([50])
        await rig.begin()
        let items = [
            ItemFixtures.item("a", tool: .claudeCode, size: 5 * gb), ItemFixtures.item("b", tool: .claudeCode, size: 1 * gb),
            ItemFixtures.item("c", tool: .cursor, size: 2 * gb),
            ItemFixtures.item("d", tool: .codex, category: .systemJunk, size: 9 * gb),   // not AI-tool data
        ]
        let summaries: [CareModule: ModuleSummary] = [
            .aiTools: ModuleSummary(module: .aiTools, safeBytes: 3 * gb, itemCount: 3),
            .systemJunk: ModuleSummary(module: .systemJunk, safeBytes: 7 * gb, itemCount: 1),
        ]
        let growth = CareGrowth(since: ItemFixtures.t0, aiToolsDelta: 3 * gb, perTool: [:])
        await rig.send(CareFix.started(), .scanEvent(.rules, .finished(ItemFixtures.result(items))),
                       .finished(CareFix.report(safe: 10 * gb, summaries: summaries, growth: growth)))
        await rig.settle()
        XCTAssertEqual(model.safeBytes, 10 * gb)
        XCTAssertNotNil(model.lastScanAt)
        XCTAssertEqual(model.aiGrowth, 3 * gb)
        XCTAssertEqual(model.topSafeModule?.module, .systemJunk)
        XCTAssertEqual(model.topSafeModule?.bytes, 7 * gb)
        XCTAssertEqual(model.topTools.map(\.tool), [.claudeCode, .cursor])
        XCTAssertEqual(model.topTools.map(\.bytes), [6 * gb, 2 * gb])
    }

    func testGrowthUnder100MBIsHiddenAndToolsCapAtFive() async {
        let (model, _, rig, _) = rig([50])
        await rig.begin()
        let tools: [ToolID] = ["t1", "t2", "t3", "t4", "t5", "t6", "t7"]
        let items = tools.enumerated().map { ItemFixtures.item("x\($0.offset)", tool: $0.element, size: Int64($0.offset + 1) * 1000) }
        let growth = CareGrowth(since: ItemFixtures.t0, aiToolsDelta: 99_000_000, perTool: [:])
        await rig.send(CareFix.started(), .scanEvent(.rules, .finished(ItemFixtures.result(items))),
                       .finished(CareFix.report(growth: growth)))
        await rig.settle()
        XCTAssertNil(model.aiGrowth)
        XCTAssertEqual(model.topTools.count, 5)
        XCTAssertEqual(model.topTools.first?.tool, "t7")
    }

    func testNextScanRowIsHiddenUntilScheduled() {
        let (model, _, _, _) = rig([50])
        XCTAssertNil(model.nextScheduledScan)
        model.nextScheduledScan = Date()
        XCTAssertNotNil(model.nextScheduledScan)
    }

    func testStatusItemCanBeHiddenAndThePreferencePersists() {
        let s = settings()
        let binding = MenuBarModel.insertedBinding(s)
        XCTAssertTrue(binding.wrappedValue)
        binding.wrappedValue = false
        XCTAssertFalse(s.settings.showMenuBarItem)
        let reloaded = settings()
        XCTAssertFalse(reloaded.settings.showMenuBarItem)
        XCTAssertFalse(MenuBarModel.insertedBinding(reloaded).wrappedValue)
    }

    func testSettingsSettersPersistAndClamp() {
        let s = settings()
        s.setMenuBarShowsFreeSpace(true)
        s.setLowSpaceAlertEnabled(false)
        s.setLowSpaceThresholdPercent(80)
        let r = settings()
        XCTAssertTrue(r.settings.menuBarShowsFreeSpace)
        XCTAssertFalse(r.settings.lowSpaceAlertEnabled)
        XCTAssertEqual(r.settings.lowSpaceThresholdPercent, 50)
    }

    func testLabelTextFollowsTheSetting() async {
        let (model, _, _, s) = rig([40])
        await model.tick()
        XCTAssertNil(model.labelFreeText)
        s.setMenuBarShowsFreeSpace(true)
        XCTAssertNotNil(model.labelFreeText)
        XCTAssertTrue(model.labelAccessibility.contains("AI Disk Keeper"))
    }
}
