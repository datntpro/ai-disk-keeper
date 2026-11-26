import DiskKeeperCore
import XCTest
@testable import AIDiskKeeperUI

@MainActor
final class UninstallerModelTests: XCTestCase {
    private let slide = UninstallFix.slide
    private let notely = UninstallFix.app("Notely", size: 2000)
    private let safari = UninstallFix.app("Safari", size: 9000, reason: .apple, source: .apple, location: .system)

    private func model(running: Set<String> = [], items: [ScanItem]? = nil,
                       runningBox: Box = Box()) -> UninstallerModel {
        runningBox.value = running
        let apps = [slide, notely, safari]
        let found = items ?? (UninstallFix.slideItems + [UninstallFix.sharedItem] + UninstallFix.orphanItems)
        return UninstallerModel(inventory: { AppInventory(apps: apps, warnings: [], scannedRoots: []) },
                                leftovers: { _ in UninstallFix.result(found) },
                                runningApps: { runningBox.value }, home: "/h")
    }

    final class Box: @unchecked Sendable { @MainActor var value: Set<String> = [] }

    private func ready(_ m: UninstallerModel) async -> UninstallerModel { m.load(); await m.settle(); return m }

    private func coordinator(_ engine: FakeCleanupEngine) -> CleanupCoordinator {
        CleanupCoordinator(holder: CleanupEngineHolder(engine: engine))
    }

    private func waitForPlan(_ engine: FakeCleanupEngine) async -> CleanupPlan? {
        for _ in 0..<600 where await engine.issuedPlans.isEmpty { try? await Task.sleep(nanoseconds: 5_000_000) }
        return await engine.issuedPlans.first
    }

    func testLoadSortsBySizeViewOnlyLastAndPartitions() async {
        let m = await ready(model())
        XCTAssertEqual(m.phase, .ready)
        XCTAssertEqual(m.apps.map(\.name), ["Slidecraft", "Notely", "Safari"])
        XCTAssertEqual(m.related["app:\(slide.bundleID)"]?.count, 6)
        XCTAssertEqual(m.shared.count, 1)
        XCTAssertEqual(m.orphans.count, 3)
        m.search = "NOTE"
        XCTAssertEqual(m.filteredApps.map(\.name), ["Notely"])
        m.search = "com.test.slide"
        XCTAssertEqual(m.filteredApps.map(\.name), ["Slidecraft"])
    }

    func testInventoryFailureShowsErrorAndLeftoverFailureKeepsApps() async {
        struct Boom: Error {}
        let bad = UninstallerModel(inventory: { throw Boom() }, leftovers: { _ in UninstallFix.result([]) }, runningApps: { [] })
        bad.load(); await bad.settle()
        if case .failed = bad.phase {} else { XCTFail("expected failed") }
        let apps = [slide]
        let partial = UninstallerModel(inventory: { AppInventory(apps: apps, warnings: [], scannedRoots: []) },
                                       leftovers: { _ in throw Boom() }, runningApps: { [] })
        partial.load(); await partial.settle()
        XCTAssertEqual(partial.phase, .ready)
        XCTAssertEqual(partial.apps.count, 1)
    }

    func testSelectTicksExactOnlyAndSharedListedUnticked() async {
        let m = await ready(model())
        m.select(slide)
        XCTAssertEqual(m.tickedRelated.count, 4)
        XCTAssertEqual(m.group(for: slide).shared.count, 1)
        XCTAssertEqual(m.tickedBytes, 5000 + 300 + 200 + 50 + 1)
        m.toggle(UninstallFix.sharedItem)
        XCTAssertEqual(m.tickedRelated.count, 5)
        m.select(notely)
        XCTAssertTrue(m.tickedRelated.isEmpty)
    }

    func testRunningAndAppleAppsCannotBeUninstalled() async {
        let m = await ready(model(running: [notely.bundleID]))
        XCTAssertEqual(m.canUninstall(notely), .running)
        XCTAssertEqual(m.canUninstall(safari), .viewOnly(.apple))
        XCTAssertEqual(m.canUninstall(slide), .available)
        let engine = FakeCleanupEngine()
        let c = coordinator(engine)
        for app in [notely, safari] {
            m.select(app)
            m.uninstall(using: c)
            m.resetApp(using: c)
        }
        try? await Task.sleep(nanoseconds: 60_000_000)
        let planned = await engine.issuedPlans.count
        XCTAssertEqual(planned, 0)
    }

    func testRunningRefreshFlipsAvailability() async {
        let box = Box()
        let m = await ready(model(runningBox: box))
        XCTAssertEqual(m.canUninstall(notely), .available)
        box.value = [notely.bundleID]
        m.refreshRunning()
        XCTAssertEqual(m.canUninstall(notely), .running)
        XCTAssertEqual(m.guidance(for: notely), .running(name: "Notely"))
        box.value = []
        m.refreshRunning()
        XCTAssertEqual(m.canUninstall(notely), .available)
    }

    func testUninstallPlansBundlePlusTickedLeftovers() async {
        let m = await ready(model())
        m.select(slide)
        let engine = FakeCleanupEngine()
        m.uninstall(using: coordinator(engine))
        let plan = await waitForPlan(engine)
        let items = plan?.entries.map(\.item) ?? []
        XCTAssertEqual(items.first?.cleanupMethod, .trashApplication(bundleID: slide.bundleID))
        XCTAssertEqual(items.first?.groupID, "app:\(slide.bundleID)")
        XCTAssertEqual(Set(items.dropFirst().map(\.id)), Set(m.tickedRelated.map(\.id)))
        XCTAssertEqual(items.count, 5)
        XCTAssertFalse(items.contains { $0.ruleID == "apps.leftover.name" })
        XCTAssertEqual(plan?.reclaimableBytes, m.tickedBytes)
    }

    func testResetPlansRegenerableStateOnly() async {
        let m = await ready(model())
        m.select(slide)
        XCTAssertTrue(m.canReset)
        let engine = FakeCleanupEngine()
        m.resetApp(using: coordinator(engine))
        let items = await waitForPlan(engine)?.entries.map(\.item) ?? []
        XCTAssertEqual(Set(items.compactMap { UninstallLibrary.location(of: $0.path) }), ["Caches", "Saved Application State"])
        XCTAssertFalse(items.contains { $0.category == .application })
    }

    func testEngineRefusesAForgedRunningState() async {
        // The UI thinks Slidecraft isn't running; the engine knows better and the plan carries the blocker.
        let m = await ready(model())
        m.select(slide)
        let engine = FakeCleanupEngine()
        let bundleID = slide.makeScanItem().id
        await engine.setBlockers([bundleID: [.appRunning(bundleID: slide.bundleID)]])
        let c = coordinator(engine)
        m.uninstall(using: c)
        let plan = await waitForPlan(engine)
        XCTAssertEqual(plan?.entries.first?.blockers, [.appRunning(bundleID: slide.bundleID)])
        XCTAssertFalse(plan?.entries.first?.isExecutable ?? true)
        let executed = await engine.executedPlans.count
        XCTAssertEqual(executed, 0)
    }

    private func finish(_ m: UninstallerModel, _ c: CleanupCoordinator, outcome: CleanupOutcome, trashed: Set<ScanItem.ID> = []) {
        let item = slide.makeScanItem()
        let r = CleanupItemResult(itemID: item.id, path: item.path, bytes: 1, action: .trash, outcome: outcome, finishedAt: Date())
        let report = CleanupReport(planID: UUID(), startedAt: Date(), finishedAt: Date(), results: [r], wasCancelled: false, auditFailure: nil)
        c.finished(trashed, report: report)
    }

    func testAppManagementDenialShowsGuidance() async {
        let m = await ready(model())
        m.select(slide)
        let engine = FakeCleanupEngine()
        let c = coordinator(engine)
        m.uninstall(using: c)
        _ = await waitForPlan(engine)
        finish(m, c, outcome: .skipped([.needsAppManagementPermission(bundleID: slide.bundleID)]))
        XCTAssertEqual(m.lastGuidance, .appManagement(bundleID: slide.bundleID))
        XCTAssertEqual(m.guidance(for: slide), .appManagement(bundleID: slide.bundleID))
        XCTAssertTrue(m.guidance(for: slide)!.needsSettingsLink)
        XCTAssertTrue(m.apps.contains(slide))
    }

    func testRequiresAdminShowsGuidanceAndTrashedBundleRemovesTheApp() async {
        let m = await ready(model())
        m.select(slide)
        let engine = FakeCleanupEngine()
        let c = coordinator(engine)
        m.uninstall(using: c)
        _ = await waitForPlan(engine)
        finish(m, c, outcome: .skipped([.requiresAdmin(bundleID: slide.bundleID)]))
        XCTAssertEqual(m.lastGuidance, .requiresAdmin(bundleID: slide.bundleID))

        m.uninstall(using: c)
        try? await Task.sleep(nanoseconds: 50_000_000)
        finish(m, c, outcome: .trashed(trashPath: nil), trashed: Set([slide.makeScanItem().id] + UninstallFix.slideItems.map(\.id)))
        XCTAssertFalse(m.apps.contains(slide))
        XCTAssertNil(m.selectedAppID)
        XCTAssertNil(m.lastGuidance)
    }

    func testOrphansNeverPreTickedAndReviewPassesOnlyTicked() async {
        let m = await ready(model())
        XCTAssertTrue(m.orphanSelection.isEmpty)
        XCTAssertTrue(m.tickedOrphans.isEmpty)
        XCTAssertEqual(m.orphanGroups.map(\.key), ["com.ghost.app", "com.other.gone"])
        let engine = FakeCleanupEngine()
        let c = coordinator(engine)
        m.reviewOrphans(using: c)
        try? await Task.sleep(nanoseconds: 40_000_000)
        let none = await engine.issuedPlans.count
        XCTAssertEqual(none, 0)
        let pick = m.orphans[1]
        m.toggleOrphan(pick)
        m.toggleOrphan(UninstallFix.sharedItem) // not an orphan: ignored
        m.reviewOrphans(using: c)
        let items = await waitForPlan(engine)?.entries.map(\.item) ?? []
        XCTAssertEqual(items.map(\.id), [pick.id])
    }

    func testUnusedCountIgnoresViewOnlyAndCountsNeverOpened() async {
        let now = Date()
        let old = UninstallFix.app("Old", lastUsed: now.addingTimeInterval(-200 * 86_400))
        let fresh = UninstallFix.app("Fresh", lastUsed: now.addingTimeInterval(-5 * 86_400))
        let never = UninstallFix.app("Never")
        let apple = UninstallFix.app("Safari2", reason: .apple, source: .apple)
        let m = UninstallerModel(inventory: { AppInventory(apps: [old, fresh, never, apple], warnings: [], scannedRoots: []) },
                                 leftovers: { _ in UninstallFix.result([]) }, runningApps: { [] }, now: { now })
        m.load(); await m.settle()
        XCTAssertEqual(m.unusedCount, 2)
    }
}
