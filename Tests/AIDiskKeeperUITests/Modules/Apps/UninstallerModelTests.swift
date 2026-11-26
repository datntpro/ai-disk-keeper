import DiskKeeperCore
import XCTest
@testable import AIDiskKeeperUI

@MainActor
final class UninstallerModelTests: XCTestCase {
    private let slide = UninstallFix.slide
    private let notely = UninstallFix.app("Notely", size: 2000)
    private let safari = UninstallFix.app("Safari", size: 9000, reason: .apple, source: .apple, location: .system)

    private func model(running: Set<InstalledApp.ID> = [], items: [ScanItem]? = nil,
                       processes: FakeAppProcessController = FakeAppProcessController()) -> UninstallerModel {
        for id in running { processes.states[id] = AppRunState(instances: [FakeAppProcessController.instance()]) }
        let apps = [slide, notely, safari]
        let found = items ?? (UninstallFix.slideItems + [UninstallFix.sharedItem] + UninstallFix.orphanItems)
        return UninstallerModel(inventory: { AppInventory(apps: apps, warnings: [], scannedRoots: []) },
                                leftovers: { _ in UninstallFix.result(found) },
                                processes: processes, home: "/h")
    }

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
        let bad = UninstallerModel(inventory: { throw Boom() }, leftovers: { _ in UninstallFix.result([]) }, processes: FakeAppProcessController())
        bad.load(); await bad.settle()
        if case .failed = bad.phase {} else { XCTFail("expected failed") }
        let apps = [slide]
        let partial = UninstallerModel(inventory: { AppInventory(apps: apps, warnings: [], scannedRoots: []) },
                                       leftovers: { _ in throw Boom() }, processes: FakeAppProcessController())
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
        let m = await ready(model(running: [notely.id]))
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
        let fake = FakeAppProcessController()
        let m = await ready(model(processes: fake))
        XCTAssertEqual(m.canUninstall(notely), .available)
        fake.set(notely, [FakeAppProcessController.instance()])
        m.refreshRunning()
        XCTAssertEqual(m.canUninstall(notely), .running)
        XCTAssertEqual(m.guidance(for: notely), .running(name: "Notely"))
        fake.clear(notely)
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

    func testUnusedCountIgnoresViewOnlyAndUnknownUsage() async {
        let now = Date()
        let old = UninstallFix.app("Old", lastUsed: now.addingTimeInterval(-200 * 86_400))
        let fresh = UninstallFix.app("Fresh", lastUsed: now.addingTimeInterval(-5 * 86_400))
        let never = UninstallFix.app("Never")
        let apple = UninstallFix.app("Safari2", reason: .apple, source: .apple)
        let m = UninstallerModel(inventory: { AppInventory(apps: [old, fresh, never, apple], warnings: [], scannedRoots: []) },
                                 leftovers: { _ in UninstallFix.result([]) }, processes: FakeAppProcessController(), now: { now })
        m.load(); await m.settle()
        XCTAssertEqual(m.unusedCount, 1) // no record = unknown (Spotlight off), not unused
    }

    func testSharedGroupContainerShownUnderAppsWithMatchingTeamUnticked() async {
        let a = UninstallFix.app("Alpha", source: .developerID(teamID: "ABCDE12345"))
        let b = UninstallFix.app("Alpha", id: "com.test.alpha2", source: .appStore(teamID: "abcde12345"))
        let other = UninstallFix.app("Other", source: .developerID(teamID: "ZZZZZ99999"))
        let team = UninstallFix.leftover(nil, "Group Containers", "ABCDE12345.shared", rule: "apps.leftover.name", size: 10)
        let m = UninstallerModel(inventory: { AppInventory(apps: [a, b, other], warnings: [], scannedRoots: []) },
                                 leftovers: { _ in UninstallFix.result([team]) }, processes: FakeAppProcessController(), home: "/h")
        m.load(); await m.settle()
        for app in [a, b] { XCTAssertEqual(m.group(for: app).shared.map(\.id), [team.id]) }
        XCTAssertTrue(m.group(for: other).shared.isEmpty)
        XCTAssertEqual(Set(m.owners(of: team).map(\.bundleID)), [a.bundleID, b.bundleID])
        XCTAssertEqual(m.ownerNames(of: team), "Alpha") // equal names listed once
        m.select(a)
        XCTAssertFalse(m.selection.isTicked(team))
        XCTAssertEqual(UninstallRelatedKind(team), .shared)
    }

    func testLeftoverScanFailureIsFlagged() async {
        struct Boom: Error {}
        let m = UninstallerModel(inventory: { AppInventory(apps: [self.slide], warnings: [], scannedRoots: []) },
                                 leftovers: { _ in throw Boom() }, processes: FakeAppProcessController())
        XCTAssertFalse(m.leftoversFailed)
        m.load(); await m.settle()
        XCTAssertTrue(m.leftoversFailed)
        XCTAssertEqual(m.phase, .ready)
        let ok = await ready(model())
        XCTAssertFalse(ok.leftoversFailed)
    }

    func testPluralCopyAndEmptyOrphanTab() {
        XCTAssertTrue(UninstallerCopy.total("1 kB", "1", count: 1).hasSuffix("1 related item"))
        XCTAssertTrue(UninstallerCopy.total("1 kB", "2", count: 2).hasSuffix("2 related items"))
        XCTAssertTrue(UninstallerCopy.barSummary("1", count: 1).hasSuffix("item"))
        XCTAssertEqual(UninstallerCopy.tabOrphans(""), "Orphaned leftovers")
    }
}
