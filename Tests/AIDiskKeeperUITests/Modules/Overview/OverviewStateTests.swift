import DiskKeeperCore
import XCTest
@testable import AIDiskKeeperUI

@MainActor
final class OverviewStateTests: XCTestCase {
    func testBeforeStartedStagesFinished() async {
        let rig = CareRig()
        let m = rig.model
        XCTAssertEqual(m.phase, .before)
        XCTAssertEqual(m.primaryAction, .scan)
        XCTAssertEqual(m.chipState(.aiTools), .pending)

        await rig.begin()
        XCTAssertEqual(m.phase, .scanning)
        XCTAssertEqual(m.primaryAction, .stop)

        await rig.send(CareFix.started(), .stageStarted(.rules))
        await rig.settle()
        XCTAssertEqual(m.chipState(.aiTools), .running(nil))
        XCTAssertEqual(m.chipState(.largeOld), .pending)

        let ai = ModuleSummary(module: .aiTools, safeBytes: 800, reviewBytes: 200, itemCount: 4)
        await rig.send(.stageProgress(.rules, 0.5), .stageFinished(.rules, [ai]), .stageStarted(.largeOld))
        await rig.settle()
        XCTAssertEqual(m.chipState(.aiTools), .done)
        XCTAssertEqual(m.chipState(.largeOld), .running(nil))
        XCTAssertEqual(m.summaries[.aiTools], ai)
        XCTAssertEqual(m.progressFraction, 1.0 / 6.0, accuracy: 0.001)

        await rig.send(.finished(CareFix.report(safe: 800, review: 200, keep: 50, summaries: [.aiTools: ai])))
        await rig.waitUntil { m.phase == .results }
        XCTAssertEqual(m.phase, .results)
        XCTAssertEqual(m.primaryAction, .review(1000))
        XCTAssertEqual(m.totals?.keepBytes, 50)
        XCTAssertEqual(m.lastFinishedAt, ItemFixtures.t0.addingTimeInterval(5))
        XCTAssertEqual(m.summaries[.aiTools]?.itemCount, 4)
    }

    func testCancelledEndsStoppedWithPartialResults() async {
        let rig = CareRig()
        await rig.begin()
        await rig.send(CareFix.started(), .stageStarted(.rules))
        rig.model.stop()
        await rig.waitUntil { rig.model.phase == .stopped }
        XCTAssertEqual(rig.model.phase, .stopped)
        XCTAssertEqual(rig.model.primaryAction, .scan)
        let calls = await rig.coordinator.cancelCalls
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(rig.announcements, [loc("status.stopped", "Scan stopped. Results are partial.")])
    }

    func testStageFailureShowsAFailedChipAndTheRestComplete() async {
        let rig = CareRig()
        await rig.begin()
        let warning = ScanWarning(kind: .scannerFailed, message: "index: boom", code: .scannerFailed(scannerID: "index"))
        let dup = ModuleSummary(module: .duplicates, reviewBytes: 2_000_000, itemCount: 2)
        await rig.send(CareFix.started(), .stageStarted(.index), .stageFailed(.index, warning),
                       .stageSkipped(.largeOld, reason: .needsTree), .stageStarted(.duplicates),
                       .stageFinished(.duplicates, [dup]),
                       .finished(CareFix.report(review: 2_000_000, summaries: [.duplicates: dup], failed: [.index])))
        await rig.waitUntil { rig.model.phase == .results }
        let m = rig.model
        XCTAssertEqual(m.stageState[.index], .failed)
        XCTAssertEqual(m.chipState(.largeOld), .skipped)
        XCTAssertEqual(m.chipState(.duplicates), .done)
        XCTAssertNotNil(m.stageFailures[.index])
        XCTAssertEqual(OverviewModuleTiles.tiles(summaries: m.summaries, enabled: [.duplicates]), [.duplicates])
    }

    func testRuleEventsReachTheScanViewModel() async {
        let rig = CareRig()
        await rig.begin()
        let a = ItemFixtures.item("a", size: 500)
        let b = ItemFixtures.item("b", tier: .review, size: 300)
        await rig.send(CareFix.started(), .stageStarted(.rules),
                       .scanEvent(.rules, CareFix.ruleStarted), .scanEvent(.rules, .itemFound(a)), .scanEvent(.rules, .itemFound(b)),
                       .scanEvent(.apps, .itemFound(ItemFixtures.item("leftover", category: .appLeftover))),
                       .scanEvent(.rules, .finished(ItemFixtures.result([a, b]))))
        await rig.waitUntil { rig.scan.phase == .finished }
        XCTAssertEqual(rig.scan.items.map(\.id).sorted(), [a.id, b.id].sorted())
        await rig.send(.finished(CareFix.report(safe: 500, review: 300)))
        await rig.waitUntil { rig.model.phase == .results }
        XCTAssertEqual(rig.scan.items.count, 2)
    }

    func testAnnouncementCarriesTheSafeTotalInBothLanguages() async {
        let rig = CareRig()
        await rig.begin()
        await rig.send(CareFix.started(), .finished(CareFix.report(safe: 5_000_000_000, review: 1_000_000_000)))
        await rig.waitUntil { rig.model.phase == .results }
        let safe = Formatting.bytes(5_000_000_000), review = Formatting.bytes(1_000_000_000)
        XCTAssertEqual(rig.announcements, [OverviewCopy.finishedAnnouncement(safe: safe, review: review)])
        XCTAssertTrue(rig.announcements[0].contains(safe))
        for lang in [AppLanguage.en, .vi] {
            L10n.withLanguage(lang) {
                let text = OverviewCopy.finishedAnnouncement(safe: "5 GB", review: "1 GB")
                XCTAssertTrue(text.contains("5 GB"), "\(lang)")
                XCTAssertFalse(text.contains("care.announce"), "\(lang)")
            }
        }
        L10n.withLanguage(.vi) {
            XCTAssertTrue(OverviewCopy.finishedAnnouncement(safe: "5 GB", review: "1 GB").hasPrefix("Đã quét tổng thể xong"))
        }
    }

    func testGrowthLineHonoursTheThreshold() async {
        let rig = CareRig()
        await rig.begin()
        let up = CareGrowth(since: ItemFixtures.t0, aiToolsDelta: 300_000_000, perTool: [:])
        await rig.send(CareFix.started(), .finished(CareFix.report(growth: up)))
        await rig.waitUntil { rig.model.phase == .results }
        XCTAssertEqual(rig.model.growthLine, OverviewCopy.growthUp(Formatting.bytes(300_000_000)))

        let rig2 = CareRig()
        await rig2.begin()
        let small = CareGrowth(since: ItemFixtures.t0, aiToolsDelta: -50_000_000, perTool: [:])
        await rig2.send(CareFix.started(), .finished(CareFix.report(growth: small)))
        await rig2.waitUntil { rig2.model.phase == .results }
        XCTAssertNil(rig2.model.growthLine)
    }

    func testChipsShowWhenEnabledOrWhenTheStageExists() {
        let rig = CareRig()
        let before = rig.model.visibleChips(enabled: [.aiTools])
        XCTAssertTrue(before.contains(.aiTools))
        XCTAssertTrue(before.contains(.systemJunk))
        XCTAssertFalse(before.contains(.apps))   // Uninstaller not enabled, no stage yet
    }
}
