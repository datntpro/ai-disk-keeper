import DiskKeeperCore
import XCTest
@testable import DiskKeeperCore
@testable import AIDiskKeeperUI

@MainActor
final class CareScanModelTests: XCTestCase {
    private let env = PathEnvironment(home: DupUI.home, temporaryDirectory: "/tmp/adk-t43")

    /// A scan result with the rule stage finished, so `scan.items` holds Safe + Review + Keep items.
    private func scanned(_ rig: CareRig, _ items: [ScanItem]) async {
        await rig.begin()
        await rig.send(CareFix.started(), .stageStarted(.rules), .scanEvent(.rules, CareFix.ruleStarted))
        for i in items { await rig.send(.scanEvent(.rules, .itemFound(i))) }
        await rig.send(.scanEvent(.rules, .finished(ItemFixtures.result(items))), .finished(CareFix.report(safe: 1, review: 1)))
        await rig.waitUntil { rig.model.phase == .results && rig.scan.phase == .finished }
    }

    func testCleanSafeOnlyOpensTheSheetWithOnlySafeItemsAndNeverExecutes() async {
        let rig = CareRig()
        let safe1 = ItemFixtures.item("cache1", tier: .safe, size: 500)
        let safe2 = ItemFixtures.item("cache2", tier: .safe, size: 400)
        let review = ItemFixtures.item("logs", tier: .review, size: 900)
        let keep = ItemFixtures.item("keepme", tier: .keep, size: 1500)
        await scanned(rig, [safe1, safe2, review, keep])

        let engine = FakeCleanupEngine()
        let coordinator = CleanupCoordinator(holder: CleanupEngineHolder(engine: engine))
        let selection = SelectionModel()
        selection.setSelected(review, true)   // a stale manual selection must not survive
        rig.model.cleanSafeOnly(using: coordinator, selection: selection)

        XCTAssertEqual(selection.selectedIDs, [safe1.id, safe2.id])
        XCTAssertTrue(selection.selectedItems(in: rig.scan.items).allSatisfy { $0.isBulkSelectable && $0.tier == .safe })
        await rig.waitUntil { await engine.issuedPlans.count == 1 }
        let plans = await engine.issuedPlans
        XCTAssertEqual(plans.count, 1)
        XCTAssertEqual(Set(plans[0].entries.map(\.item.id)), [safe1.id, safe2.id])
        let executed = await engine.executedPlans
        XCTAssertTrue(executed.isEmpty, "the dry-run sheet must be confirmed first")
        XCTAssertTrue(coordinator.isPresented)
    }

    func testCleanSafeOnlyWithNothingSafeDoesNothing() async {
        let rig = CareRig()
        await scanned(rig, [ItemFixtures.item("logs", tier: .review, size: 900)])
        let engine = FakeCleanupEngine()
        let coordinator = CleanupCoordinator(holder: CleanupEngineHolder(engine: engine))
        let selection = SelectionModel()
        rig.model.cleanSafeOnly(using: coordinator, selection: selection)
        XCTAssertTrue(selection.selectedIDs.isEmpty)
        XCTAssertFalse(coordinator.isPresented)
        XCTAssertEqual(rig.model.safeBulkBytes, 0)
    }

    func testDuplicatesArtifactIsAdoptedWithoutHashing() async {
        let rig = CareRig()
        let fakeIdx = rig.fakeIndexer
        rig.index.start(.home)
        await rig.waitUntil { await fakeIdx.isWaiting }
        await fakeIdx.finish(FakeDiskIndexer.tree())
        await rig.waitUntil { rig.index.phase == .ready }

        let env = env
        let dup = DuplicatesModel(index: rig.index, finder: { _, _, _ in XCTFail("must not hash again"); return DupUI.report([]) },
                                  environment: env, guardProvider: { try ScanGuard(environment: env, protectPatterns: []) },
                                  makeItems: { report, rule, _, _ in
                                      var out: [String: [ScanItem]] = [:]
                                      for g in report.groups { out[g.id] = g.members.map { DuplicateScanner.makeItem($0, group: g, keeper: g.keeper, rule: rule) } }
                                      return out
                                  })
        rig.duplicates = dup
        rig.largeOld = LargeOldModel(index: rig.index, scanner: { _ in XCTFail("must not analyse again"); return LargeFileReport(files: []) })

        await rig.begin()
        let report = DupUI.report([DupUI.plain("a", count: 3)])
        let large = LargeOldFix.report()
        await rig.send(CareFix.started(), .artifact(.duplicates(report)), .artifact(.largeFiles(large)),
                       .finished(CareFix.report()))
        await rig.waitUntil { dup.phase == .ready }
        XCTAssertEqual(dup.phase, .ready)
        XCTAssertEqual(dup.groups.count, 1)
        XCTAssertEqual(dup.finderRuns, 0)
        XCTAssertEqual(rig.largeOld?.phase, .ready)
        XCTAssertEqual(rig.largeOld?.report?.files.count, large.files.count)
        // The screen opening afterwards does not re-hash: the generation is the adopted one.
        dup.refreshIfNeeded()
        XCTAssertEqual(dup.finderRuns, 0)
        await rig.largeOld?.refresh()
        XCTAssertEqual(rig.largeOld?.phase, .ready)
    }

    func testDiskIndexBuildAwaitsTheTreeAndPublishesIt() async throws {
        let fake = FakeDiskIndexer()
        let index = DiskIndexModel(makeIndexer: { fake }, fullDiskAccess: { false })
        let build = Task { try await index.build(.home) }
        for _ in 0..<400 where !(await fake.isWaiting) { try await Task.sleep(nanoseconds: 5_000_000) }
        await fake.finish(FakeDiskIndexer.tree())
        let tree = try await build.value
        XCTAssertEqual(index.phase, .ready)
        XCTAssertEqual(index.generation, 1)
        XCTAssertNotNil(index.tree)
        XCTAssertEqual(tree.rootPath, index.tree?.rootPath)
    }

    func testDiskIndexBuildThrowsWhenCancelled() async throws {
        let fake = FakeDiskIndexer()
        let index = DiskIndexModel(makeIndexer: { fake }, fullDiskAccess: { false })
        let build = Task { try await index.build(.home) }
        for _ in 0..<400 where !(await fake.isWaiting) { try await Task.sleep(nanoseconds: 5_000_000) }
        build.cancel()
        do { _ = try await build.value; XCTFail("expected cancellation") } catch is CancellationError {}
        XCTAssertNotEqual(index.phase, .ready)
    }

    func testWholeDiskBuildWithoutFDAIsRefused() async {
        let index = DiskIndexModel(makeIndexer: { FakeDiskIndexer() }, fullDiskAccess: { false })
        do { _ = try await index.build(.fullDisk); XCTFail("expected a refusal") } catch {
            XCTAssertEqual(error as? DiskIndexBuildError, .refused)
        }
    }

    func testFingerprintChangesWithScopeAndIndex() {
        let a = CareScanLive.fingerprint(scope: .unrestricted, index: .home)
        XCTAssertEqual(a, CareScanLive.fingerprint(scope: .unrestricted, index: .home))
        XCTAssertNotEqual(a, CareScanLive.fingerprint(scope: .unrestricted, index: .fullDisk))
        XCTAssertNotEqual(a, CareScanLive.fingerprint(scope: ScanScope(excludedPaths: [], disabledTools: [.claudeCode], projectRoots: []), index: .home))
    }
}
