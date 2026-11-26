import DiskKeeperCore
import XCTest
@testable import AIDiskKeeperUI

/// Every test here uses `FakeAppProcessController`: nothing real is quit, launched or activated.
@MainActor
final class UninstallQuitFlowTests: XCTestCase {
    private let notely = UninstallFix.app("Notely", size: 2000)
    private let slide = UninstallFix.slide
    private let safari = UninstallFix.app("Safari", size: 9000, reason: .apple, source: .apple, location: .system)
    private let me = UninstallFix.app("AI Disk Keeper", id: "com.aidiskkeeper.app", size: 10)
    private let identity = SelfIdentity(bundleID: "com.aidiskkeeper.app", path: "/h/Applications/AI Disk Keeper.app", pid: 1111, uid: 501)

    final class Counter: @unchecked Sendable { var inventories = 0; var apps: [InstalledApp] = [] }

    private struct Rig {
        let m: UninstallerModel
        let fake: FakeAppProcessController
        let clock: FakeClock
        let audit: AuditRecorder
        let counter: Counter
    }

    private func rig(_ fake: FakeAppProcessController = FakeAppProcessController()) async -> Rig {
        let clock = FakeClock(), audit = AuditRecorder(), counter = Counter()
        counter.apps = [slide, notely, safari, me]
        let m = UninstallerModel(inventory: { counter.inventories += 1; return AppInventory(apps: counter.apps, warnings: [], scannedRoots: []) },
                                 leftovers: { _ in UninstallFix.result([]) }, processes: fake, audit: audit.write, identity: identity,
                                 sleep: { try await clock.sleep($0) }, home: "/h", now: { clock.now() })
        m.load()
        await m.settle()
        return Rig(m: m, fake: fake, clock: clock, audit: audit, counter: counter)
    }

    private func until(_ what: String = "", _ cond: () -> Bool) async {
        for _ in 0..<2000 where !cond() { try? await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertTrue(cond(), "timed out: \(what)")
    }

    private func flow(_ r: Rig, _ app: InstalledApp, _ state: QuitFlowState) async {
        await until("\(state)") { r.m.quitFlows[app.id] == state }
    }

    private func start(_ r: Rig, running instances: [AppInstance], select app: InstalledApp? = nil) -> InstalledApp {
        let app = app ?? notely
        r.fake.set(app, instances)
        r.m.select(app)
        r.m.refreshRunning()
        return app
    }

    private func main(_ pid: pid_t = 4242) -> AppInstance { FakeAppProcessController.instance(.main, pid: pid) }

    // 1
    func testRunningAppOffersQuitAndBlocksUninstall() async {
        let r = await rig()
        let app = start(r, running: [main()])
        XCTAssertEqual(r.m.canUninstall(app), .running)
        XCTAssertTrue(r.m.canQuit(app))
        XCTAssertEqual(r.m.guidance(for: app), .running(name: "Notely", quit: nil, background: [], otherUser: false, canQuit: true))
        XCTAssertFalse(r.m.canReset)
    }

    // 2, 3
    func testQuitAsksMainAndHelperNeverBackgroundThenDoneWithoutRescan() async {
        let r = await rig()
        let helper = FakeAppProcessController.instance(.helperApp, pid: 5, name: "Helper")
        let bg = FakeAppProcessController.instance(.background, pid: 6, name: "adkqa-bg")
        let app = start(r, running: [main(), helper, bg])
        r.fake.onQuit = { [fake = r.fake] i in fake.set(app, fake.states[app.id]!.instances.filter { $0.pid != i.pid }) }
        r.m.quit(app)
        XCTAssertEqual(r.m.quitFlows[app.id], .quitting)
        // Only the background process is left: the flow ends with it listed, never signalled.
        await flow(r, app, .backgroundRemains)
        XCTAssertEqual(Set(r.fake.quits.map(\.pid)), [4242, 5])
        XCTAssertTrue(r.fake.forces.isEmpty)
        XCTAssertEqual(r.m.canUninstall(app), .running)
        r.fake.set(app, [])
        r.m.refreshRunning()
        XCTAssertEqual(r.m.canUninstall(app), .available)
        XCTAssertEqual(r.counter.inventories, 1, "no re-scan")
    }

    func testPlainQuitReachesDoneAndAuditsRequestedThenResult() async {
        let r = await rig()
        let app = start(r, running: [main()])
        r.fake.onQuit = { [fake = r.fake] _ in fake.clear(app) }
        r.m.quit(app)
        await flow(r, app, .done)
        XCTAssertEqual(r.m.canUninstall(app), .available)
        XCTAssertEqual(r.m.guidance(for: app), .quitDone(name: "Notely"))
        r.m.select(slide)
        XCTAssertNil(r.m.quitFlows[app.id], "done confirmation goes away with the next selection")
        XCTAssertEqual(r.audit.records.map { "\($0.mode)/\($0.phase)/\($0.result ?? "-")" }, ["graceful/requested/-", "graceful/result/quit"])
        XCTAssertEqual(r.audit.records.first?.bundleID, notely.bundleID)
        XCTAssertEqual(r.counter.inventories, 1)
    }

    // 4, 5
    func testStillOpenAfterFiveSecondsIsStuckAndForceNeedsConfirmationAndAuditFirst() async {
        let r = await rig()
        let app = start(r, running: [main()])
        r.m.quit(app)
        await flow(r, app, .stuck)
        XCTAssertGreaterThanOrEqual(r.clock.current.timeIntervalSince(Date(timeIntervalSince1970: 1_000_000)), 5)
        XCTAssertTrue(r.fake.forces.isEmpty)
        r.m.requestForceQuit(app)
        XCTAssertEqual(r.m.forceConfirmation, ForceConfirmation(appID: app.id, name: "Notely", instances: 1))
        XCTAssertTrue(r.fake.forces.isEmpty, "not without the confirmation")
        var auditedFirst = false
        r.fake.onForce = { [fake = r.fake, audit = r.audit] _ in
            auditedFirst = audit.records.contains { $0.mode == "force" && $0.phase == "requested" }
            fake.clear(app)
        }
        r.m.confirmForceQuit()
        await flow(r, app, .done)
        XCTAssertTrue(auditedFirst)
        XCTAssertEqual(r.fake.forces.count, 1)
        XCTAssertEqual(r.audit.records.filter { $0.mode == "force" }.map(\.phase), ["requested", "result"])
        XCTAssertEqual(r.audit.records.last?.result, "quit")
    }

    // 6
    func testForceQuitIsFailClosedOnTheAuditLog() async {
        let r = await rig()
        let app = start(r, running: [main()])
        r.m.quit(app)
        await flow(r, app, .stuck)
        r.audit.failRequestedForce = true
        r.m.requestForceQuit(app)
        r.m.confirmForceQuit()
        await flow(r, app, .auditFailed)
        XCTAssertTrue(r.fake.forces.isEmpty)
        guard case .running(_, .auditFailed?, _, _, _)? = r.m.guidance(for: app) else { return XCTFail("guidance") }
        XCTAssertEqual(UninstallGuidanceCard.text(r.m.guidance(for: app)!), UninstallerCopy.auditFailed)
    }

    // 7
    func testCancellingTheConfirmationDoesNothing() async {
        let r = await rig()
        let app = start(r, running: [main()])
        r.m.quit(app)
        await flow(r, app, .stuck)
        r.m.requestForceQuit(app)
        r.m.cancelForceQuit()
        r.m.confirmForceQuit()
        XCTAssertNil(r.m.forceConfirmation)
        XCTAssertTrue(r.fake.forces.isEmpty)
        XCTAssertEqual(r.m.quitFlows[app.id], .stuck)
    }

    // 8
    func testSavingInTheAppsDialogLaterEndsTheFlowWithoutForce() async {
        let r = await rig()
        let app = start(r, running: [main()])
        r.m.quit(app)
        await flow(r, app, .stuck)
        r.fake.clear(app) // the user chose "Save"; the app quit by itself
        r.m.refreshRunning()
        await flow(r, app, .done)
        XCTAssertTrue(r.fake.forces.isEmpty)
        XCTAssertEqual(r.m.canUninstall(app), .available)
    }

    // 9
    func testQuitRequestRefusedByEveryTargetIsStuckAtOnce() async {
        let r = await rig()
        r.fake.quitResult = false
        let app = start(r, running: [main()])
        r.m.quit(app)
        await flow(r, app, .stuck)
        XCTAssertEqual(r.clock.ticks, 0)
    }

    // 10
    func testTwoCopiesBothAskedAndConfirmationCountsThem() async {
        let r = await rig()
        let app = start(r, running: [main(101), main(102)])
        r.m.quit(app)
        await flow(r, app, .stuck)
        XCTAssertEqual(r.fake.quits.count, 2)
        r.m.requestForceQuit(app)
        XCTAssertEqual(r.m.forceConfirmation?.instances, 2)
        r.m.cancelForceQuit()
        // One copy quits: not done yet.
        r.fake.set(app, [main(102)])
        r.m.quit(app)
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertNotEqual(r.m.quitFlows[app.id], .done)
        await flow(r, app, .stuck)
    }

    // 11
    func testRelaunchedAppIsReportedAndNotQuitAgain() async {
        let r = await rig()
        let app = start(r, running: [main()])
        r.fake.onQuit = { [fake = r.fake] _ in fake.clear(app) }
        r.clock.onTick = { [fake = r.fake, me = self] _ in fake.set(app, [me.main(9)]) }
        r.m.quit(app)
        await flow(r, app, .relaunched)
        XCTAssertEqual(r.fake.quits.count, 1)
        XCTAssertEqual(r.m.canUninstall(app), .running)
        XCTAssertFalse(r.m.canQuit(app))
        XCTAssertTrue(UninstallGuidanceCard.text(r.m.guidance(for: app)!).contains("Startup Items"))
    }

    // 12, 17
    func testOnlyBackgroundProcessLeftListsItAndBlocksUninstall() async {
        let r = await rig()
        let bg = FakeAppProcessController.instance(.background, pid: 77, name: "adkqa-bg")
        let app = start(r, running: [bg])
        XCTAssertEqual(r.m.canUninstall(app), .running, "engine and screen agree")
        XCTAssertFalse(r.m.canQuit(app))
        XCTAssertEqual(r.m.guidance(for: app), .running(name: "Notely", quit: nil, background: ["adkqa-bg (77)"], otherUser: false, canQuit: false))
        XCTAssertTrue(UninstallGuidanceCard.text(r.m.guidance(for: app)!).contains("adkqa-bg (77)"))
        r.m.quit(app)
        XCTAssertTrue(r.fake.quits.isEmpty)
    }

    // 13
    func testUnreadableProcessListFailsClosed() async {
        let fake = FakeAppProcessController()
        fake.unreadable = true
        let r = await rig(fake)
        r.m.select(notely)
        XCTAssertTrue(r.m.runningUnknown)
        XCTAssertEqual(r.m.canUninstall(notely), .running)
        XCTAssertEqual(r.m.guidance(for: notely), .runningUnknown(name: "Notely"))
        XCTAssertFalse(r.m.canQuit(notely))
        XCTAssertEqual(r.m.canUninstall(safari), .viewOnly(.apple))
        r.m.quit(notely)
        XCTAssertTrue(fake.quits.isEmpty)
        fake.unreadable = false
        r.m.refreshRunning()
        XCTAssertEqual(r.m.canUninstall(notely), .available)
    }

    // 14
    func testRefusals() async {
        let r = await rig()
        // Apple / view-only
        r.fake.set(safari, [FakeAppProcessController.instance(.main, pid: 31, bundleID: "com.apple.Safari")])
        r.m.select(safari); r.m.refreshRunning()
        XCTAssertFalse(r.m.canQuit(safari))
        XCTAssertEqual(r.m.guidance(for: safari), .locked(.apple))
        r.m.quit(safari)
        // Ourselves
        r.fake.set(me, [FakeAppProcessController.instance(.main, pid: 1111, bundleID: "com.aidiskkeeper.app")])
        r.m.select(me); r.m.refreshRunning()
        XCTAssertFalse(r.m.canQuit(me))
        XCTAssertEqual(r.m.guidance(for: me), .selfApp)
        r.m.quit(me)
        // Another user's copy
        r.fake.set(notely, [FakeAppProcessController.instance(.main, pid: 8, ours: false)])
        r.m.select(notely); r.m.refreshRunning()
        XCTAssertFalse(r.m.canQuit(notely))
        XCTAssertEqual(r.m.guidance(for: notely), .running(name: "Notely", quit: nil, background: [], otherUser: true, canQuit: false))
        r.m.quit(notely)
        // Owner unknown counts as someone else's.
        r.fake.set(notely, [FakeAppProcessController.instance(.main, pid: 8, ours: nil)])
        r.m.refreshRunning()
        XCTAssertFalse(r.m.canQuit(notely))
        XCTAssertTrue(r.fake.quits.isEmpty)
        XCTAssertTrue(r.fake.forces.isEmpty)
        XCTAssertTrue(r.fake.activations.isEmpty)
    }

    // 15
    func testSecondQuitIsIgnoredWhileBusyAndBlockedWhileTheSheetIsOpen() async {
        let r = await rig()
        let app = start(r, running: [main()])
        let engine = FakeCleanupEngine()
        let c = CleanupCoordinator(holder: CleanupEngineHolder(engine: engine))
        c.review([slide.makeScanItem()]) { _ in }
        if c.isPresented {
            r.m.quit(app, coordinator: c)
            XCTAssertNil(r.m.quitFlows[app.id])
        }
        r.m.quit(app)
        r.m.quit(app)
        await flow(r, app, .stuck)
        XCTAssertEqual(r.fake.quits.count, 1)
    }

    // 16
    func testFlowSurvivesSelectionChangeAndIsDroppedWhenTheAppDisappears() async {
        let r = await rig()
        let app = start(r, running: [main()])
        r.m.quit(app)
        r.m.select(slide)
        await flow(r, app, .stuck)
        r.m.select(app)
        XCTAssertEqual(r.m.quitFlows[app.id], .stuck)
        r.counter.apps = [slide, safari, me]
        r.m.load()
        await r.m.settle()
        XCTAssertNil(r.m.quitFlows[app.id])
    }

    // 18
    func testForceQuitThatDoesNotWorkFailsAndOffersItAgain() async {
        let r = await rig()
        let app = start(r, running: [main()])
        r.m.quit(app)
        await flow(r, app, .stuck)
        r.m.requestForceQuit(app)
        r.m.confirmForceQuit()
        await flow(r, app, .failed)
        XCTAssertTrue(r.m.quitFlows[app.id]?.isStuck == true)
        r.m.requestForceQuit(app)
        XCTAssertNotNil(r.m.forceConfirmation)
        XCTAssertEqual(r.audit.records.last?.result, "stillRunning")
    }

    func testShowAppActivatesTheMainInstance() async {
        let r = await rig()
        let app = start(r, running: [main()])
        r.m.showApp(app)
        XCTAssertEqual(r.fake.activations.map(\.pid), [4242])
    }
}
