import DiskKeeperCore
import XCTest
@testable import DiskKeeperCore
@testable import AIDiskKeeperUI

private final class IndexerBox: @unchecked Sendable {
    let fake: FakeDiskIndexer
    init(_ f: FakeDiskIndexer) { fake = f }
}

private actor Counter {
    private(set) var runs = 0
    func hit() { runs += 1 }
}

@MainActor
final class LargeOldModelTests: XCTestCase {
    private func make(_ report: LargeFileReport = LargeOldFix.report(), fake: FakeDiskIndexer = FakeDiskIndexer(),
                      counter: Counter = Counter()) -> (LargeOldModel, DiskIndexModel, FakeDiskIndexer, Counter) {
        let box = IndexerBox(fake)
        let index = DiskIndexModel(makeIndexer: { box.fake }, fullDiskAccess: { false })
        let model = LargeOldModel(index: index, scanner: { _ in await counter.hit(); return report },
                                  now: { LargeOldFix.now })
        return (model, index, fake, counter)
    }

    private func buildIndex(_ index: DiskIndexModel, _ fake: FakeDiskIndexer) async {
        index.start(.home)
        await LargeOldFix.wait { index.phase == .indexing }
        for _ in 0..<600 where !(await fake.isWaiting) { try? await Task.sleep(nanoseconds: 5_000_000) }
        await fake.finish(FakeDiskIndexer.tree())
        await LargeOldFix.wait { index.phase == .ready }
    }

    func testNeedsIndexThenAnalysingThenReady() async {
        let (model, index, fake, counter) = make()
        await model.refresh()
        XCTAssertEqual(model.phase, .needsIndex)
        await buildIndex(index, fake)
        await model.refresh()
        XCTAssertEqual(model.phase, .ready)
        let runs = await counter.runs
        XCTAssertEqual(runs, 1)
        XCTAssertEqual(model.rows.count, 5)   // default filters
        XCTAssertEqual(model.rows.first?.name, "Archive-2024.zip")   // size ↓
        await model.refresh()                   // same generation → no second run
        let again = await counter.runs
        XCTAssertEqual(again, 1)
    }

    func testNewGenerationReanalysesAndClearsSelection() async {
        let (model, index, fake, counter) = make(fake: FakeDiskIndexer())
        await buildIndex(index, fake)
        await model.refresh()
        let first = model.rows[0]
        model.selection.setSelected(model.item(for: first), true)
        XCTAssertEqual(model.selectedItems.count, 1)
        model.inspectedPath = first.path
        await buildIndex(index, fake)   // generation 2
        await model.refresh()
        let runs = await counter.runs
        XCTAssertEqual(runs, 2)
        XCTAssertTrue(model.selection.selectedIDs.isEmpty)
        XCTAssertNil(model.inspectedPath)
    }

    func testFailureShowsFailedPhase() async {
        struct Boom: Error {}
        let fake = FakeDiskIndexer()
        let index = DiskIndexModel(makeIndexer: { fake }, fullDiskAccess: { false })
        let model = LargeOldModel(index: index, scanner: { _ in throw Boom() }, now: { LargeOldFix.now })
        await buildIndex(index, fake)
        await model.refresh()
        if case .failed = model.phase {} else { XCTFail("expected failed, got \(model.phase)") }
    }

    func testKindTotalsRespectOtherFiltersButNotKinds() async {
        let (model, index, fake, _) = make()
        await buildIndex(index, fake)
        await model.refresh()
        model.toggleKind(.video)
        XCTAssertEqual(model.rows.map(\.name), ["demo.mov"])
        XCTAssertEqual(model.kindTotals[.archive]?.count, 1)
        XCTAssertEqual(model.kindTotals[.video]?.count, 1)   // recent.mov is newer than 6 months
        model.filters.age = .any
        XCTAssertEqual(model.kindTotals[.video]?.count, 2)
        XCTAssertEqual(model.rows.count, 2)
    }

    func testSortByNameAndSize() async {
        let (model, index, fake, _) = make()
        await buildIndex(index, fake)
        await model.refresh()
        model.sortOrder = [LargeFileComparator(column: .name, order: .forward)]
        XCTAssertEqual(model.rows.map(\.name), ["Archive-2024.zip", "demo.mov", "Docker.dmg", "linked.bin", "Xcode_16.2.xip"])
        model.sortOrder = [LargeFileComparator(column: .size, order: .forward)]
        XCTAssertEqual(model.rows.first?.name, "Docker.dmg")
    }

    func testReviewCleanupSendsExactlySelectedItems() async {
        let (model, index, fake, _) = make()
        await buildIndex(index, fake)
        await model.refresh()
        let engine = FakeCleanupEngine()
        let coordinator = CleanupCoordinator(holder: CleanupEngineHolder(engine: engine))
        let a = model.rows[0], b = model.rows[2]
        model.selection.setSelected(model.item(for: a), true)
        model.selection.setSelected(model.item(for: b), true)
        // the report-only (hard-linked) row can't be selected
        let linked = model.rows.first { $0.linkCount > 1 }!
        model.selection.setSelected(model.item(for: linked), true)
        model.reviewCleanup(using: coordinator)
        await LargeOldFix.wait { coordinator.isPresented }
        for _ in 0..<600 where await engine.issuedPlans.isEmpty { try? await Task.sleep(nanoseconds: 5_000_000) }
        let plans = await engine.issuedPlans
        XCTAssertEqual(Set(plans.first?.entries.map(\.item.path) ?? []), [a.path, b.path])
    }

    func testFinishRemovesTrashedRowsAndClearsSelection() async {
        let (model, index, fake, _) = make()
        await buildIndex(index, fake)
        await model.refresh()
        let engine = FakeCleanupEngine()
        let coordinator = CleanupCoordinator(holder: CleanupEngineHolder(engine: engine))
        let a = model.rows[0]
        model.selection.setSelected(model.item(for: a), true)
        model.reviewCleanup(using: coordinator)
        await LargeOldFix.wait { coordinator.isPresented }
        coordinator.finished([model.item(for: a).id])
        XCTAssertFalse(model.rows.contains { $0.path == a.path })
        XCTAssertEqual(model.rows.count, 4)
        XCTAssertTrue(model.selection.selectedIDs.isEmpty)
        XCTAssertFalse(model.report?.files.contains { $0.path == a.path } ?? true)
    }

    func testBadgeCountsActionableRows() async {
        let (model, index, fake, _) = make()
        await buildIndex(index, fake)
        await model.refresh()
        // 5 default rows; the hard-linked 700 MB one is report-only
        XCTAssertEqual(model.badgeBytes, (9000 + 2900 + 1200 + 610) * 1_000_000)
    }

    func testFolderChoices() async {
        let (model, index, fake, _) = make()
        await buildIndex(index, fake)
        await model.refresh()
        let c = model.folderChoices
        XCTAssertEqual(c.first?.path, LargeOldFix.root)
        XCTAssertEqual(c.dropFirst().map(\.name), ["Documents", "Downloads", "Movies"])
    }

    func testQuickLookAndReveal() async {
        let (model, index, fake, _) = make()
        let finder = FakeFinder()
        model.finder = finder
        await buildIndex(index, fake)
        await model.refresh()
        model.handleSpace()
        XCTAssertNil(model.quickLookURL)            // nothing inspected
        let f = model.rows[1]
        model.inspectedPath = f.path
        model.handleSpace()
        XCTAssertEqual(model.quickLookURL, URL(fileURLWithPath: f.path))
        model.handleSpace()
        XCTAssertNil(model.quickLookURL)
        model.reveal(f)
        XCTAssertEqual(finder.revealed, [URL(fileURLWithPath: f.path)])
    }
}
