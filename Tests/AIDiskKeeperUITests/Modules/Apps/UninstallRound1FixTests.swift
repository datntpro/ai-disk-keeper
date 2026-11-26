import DiskKeeperCore
import XCTest
@testable import AIDiskKeeperUI

/// PR #115 verification round 1 (F2, F3, F5, F8). Fake process controller only: nothing real is quit or signalled.
@MainActor
final class UninstallRound1FixTests: XCTestCase {
    private let notely = UninstallFix.app("Notely", size: 2000)
    private let identity = SelfIdentity(bundleID: "com.aidiskkeeper.app", path: "/h/Applications/AI Disk Keeper.app", pid: 1111, uid: 501)

    private struct Rig { let m: UninstallerModel; let fake: FakeAppProcessController; let audit: AuditRecorder; let clock: FakeClock }

    private func rig() async -> Rig {
        let fake = FakeAppProcessController(), clock = FakeClock(), audit = AuditRecorder()
        let apps = [notely]
        let m = UninstallerModel(inventory: { AppInventory(apps: apps, warnings: [], scannedRoots: []) }, leftovers: { _ in UninstallFix.result([]) },
                                 processes: fake, audit: audit.write, identity: identity, sleep: { try await clock.sleep($0) },
                                 home: "/h", now: { clock.now() })
        m.load()
        await m.settle()
        return Rig(m: m, fake: fake, audit: audit, clock: clock)
    }

    private func until(_ what: String, _ cond: () -> Bool) async {
        for _ in 0..<2000 where !cond() { try? await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertTrue(cond(), "timed out: \(what)")
    }

    private func main(_ pid: pid_t = 4242) -> AppInstance { FakeAppProcessController.instance(.main, pid: pid) }

    // F2: "background remains", then the background part ends and the app is opened again: Quit is back.
    func testQuitIsOfferedAgainAfterBackgroundRemainsWhenAppReopens() async {
        let r = await rig()
        let bg = FakeAppProcessController.instance(.background, pid: 6, name: "adkqa-bg")
        r.fake.set(notely, [main(), bg])
        r.m.select(notely)
        r.fake.onQuit = { [fake = r.fake] i in fake.set(self.notely, fake.states[self.notely.id]!.instances.filter { $0.pid != i.pid }) }
        r.m.quit(notely)
        await until("backgroundRemains") { r.m.quitFlows[notely.id] == .backgroundRemains }
        r.fake.onQuit = { _ in }
        r.fake.set(notely, [main(7777)])   // relaunched by hand; no background part any more
        r.m.refreshRunning()
        XCTAssertTrue(r.m.canQuit(notely), "Quit App must come back")
        r.m.quit(notely)
        await until("second request") { r.fake.quits.count >= 2 }
        XCTAssertEqual(r.fake.quits.last?.pid, 7777)
    }

    // F2: "relaunched", then the relauncher goes away and the app stays closed: the state clears.
    func testRelaunchedStateClearsWhenTheAppIsGoneAndQuitReturnsWhenItIsOpenAgain() async {
        let r = await rig()
        r.fake.set(notely, [main()])
        r.m.select(notely)
        r.fake.onQuit = { [fake = r.fake] _ in fake.clear(self.notely) }
        r.clock.onTick = { [fake = r.fake, m = r.m] _ in   // it relaunches itself while the flow settles
            if m.quitFlows[self.notely.id] == .settling { fake.set(self.notely, [self.main(9999)]) }
        }
        r.m.quit(notely)
        await until("relaunched") { r.m.quitFlows[notely.id] == .relaunched }
        XCTAssertTrue(r.m.canQuit(notely), "second Quit allowed from relaunched")
        r.fake.clear(notely)
        r.m.refreshRunning()
        XCTAssertNil(r.m.quitFlows[notely.id], "stale relaunched state cleared once the app is not running")
        r.fake.set(notely, [main(5)])
        r.m.refreshRunning()
        XCTAssertTrue(r.m.canQuit(notely))
    }

    // F2: a "has quit" card goes when the same app is open again, without reselecting.
    func testDoneClearsWhenTheSameAppRunsAgain() async {
        let r = await rig()
        r.fake.set(notely, [main()])
        r.m.select(notely)
        r.fake.onQuit = { [fake = r.fake] _ in fake.clear(self.notely) }
        r.m.quit(notely)
        await until("done") { r.m.quitFlows[notely.id] == .done }
        r.fake.set(notely, [main(8)])
        r.m.refreshRunning()
        XCTAssertNil(r.m.quitFlows[notely.id])
        XCTAssertTrue(r.m.canQuit(notely))
    }

    // F3: the app never posts a launch notification; the screen still learns it is running before enabling Uninstall.
    func testSilentLaunchIsSeenOnSelectAndBeforeUninstall() async {
        let r = await rig()
        r.m.select(notely)
        XCTAssertEqual(r.m.canUninstall(notely), .available)
        r.fake.set(notely, [main()])            // no notification, no refreshRunning() call from outside
        let c = CleanupCoordinator(holder: CleanupEngineHolder())
        r.m.uninstall(using: c)
        XCTAssertEqual(r.m.canUninstall(notely), .running, "the click re-reads the process list")
        XCTAssertFalse(c.isPresented, "no review sheet for a running app")
        r.fake.clear(notely)
        r.m.refreshRunning()
        r.fake.set(notely, [main(3)])
        r.m.select(notely)
        XCTAssertEqual(r.m.canUninstall(notely), .running, "select re-reads too")
    }

    func testPollingPicksUpAnAppThatNeverSendsALaunchNotification() async {
        let r = await rig()
        r.m.select(notely)
        r.m.startPolling(every: .seconds(3))
        r.fake.set(notely, [main()])
        await until("polled") { r.m.canUninstall(self.notely) == .running }
        r.fake.clear(notely)
        await until("polled again") { r.m.canUninstall(self.notely) == .available }
        r.m.stopPolling()
    }

    // F5: a flow resumed after the user answered the app's save dialog keeps its flow id and targets.
    func testResumedFlowKeepsFlowIDAndTargetsInTheAudit() async {
        let r = await rig()
        r.fake.set(notely, [main(42)])
        r.m.select(notely)
        r.m.quit(notely)
        await until("stuck") { r.m.quitFlows[notely.id] == .stuck }
        r.fake.clear(notely)                    // "Don't Save"
        r.m.refreshRunning()
        await until("done") { r.m.quitFlows[notely.id] == .done }
        let lines = r.audit.records
        XCTAssertEqual(Set(lines.map(\.flowID)).count, 1, "one flow id from requested to final result")
        XCTAssertEqual(lines.last?.pids, [42])
        XCTAssertEqual(lines.last?.result, "quit")
    }

    func testAuditRecordsTheRealOutcomeNotJustQuit() async {
        let r = await rig()
        r.fake.set(notely, [main()])
        r.m.select(notely)
        r.fake.onQuit = { [fake = r.fake] _ in fake.clear(self.notely) }
        r.clock.onTick = { [fake = r.fake, m = r.m] _ in
            if m.quitFlows[self.notely.id] == .settling { fake.set(self.notely, [self.main(9999)]) }
        }
        r.m.quit(notely)
        await until("relaunched") { r.m.quitFlows[notely.id] == .relaunched }
        await until("result line") { r.audit.records.count == 2 }
        XCTAssertEqual(r.audit.records.last?.result, "relaunched")
    }

    // F8: after a plain quit the card says Quitting… until the check is done, and Uninstall stays off meanwhile.
    func testAppStaysRunningOnScreenWhileTheQuitSettles() async {
        let r = await rig()
        r.fake.set(notely, [main()])
        r.m.select(notely)
        r.fake.onQuit = { [fake = r.fake] _ in fake.clear(self.notely) }
        var whileSettling: UninstallAvailability?
        r.clock.onTick = { [m = r.m] _ in   // a didTerminate notification lands while the flow settles
            if m.quitFlows[self.notely.id] == .settling { m.refreshRunning(); whileSettling = m.canUninstall(self.notely) }
        }
        r.m.quit(notely)
        await until("done") { r.m.quitFlows[notely.id] == .done }
        XCTAssertEqual(whileSettling, .running)
        XCTAssertEqual(r.m.canUninstall(notely), .available)
    }
}
