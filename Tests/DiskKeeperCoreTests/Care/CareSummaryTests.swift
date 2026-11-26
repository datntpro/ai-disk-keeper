import XCTest
@testable import DiskKeeperCore

final class CareSummaryTests: XCTestCase {
    func testCategoryToModuleMapping() {
        let expected: [ItemCategory: CareModule] = [
            .aiToolData: .aiTools, .worktree: .worktrees, .buildArtifact: .worktrees, .modelWeights: .modelsDocker,
            .docker: .modelsDocker, .systemJunk: .systemJunk, .largeFile: .largeOld, .duplicate: .duplicates,
            .application: .apps, .appLeftover: .apps, .startupItem: .startup,
        ]
        for c in ItemCategory.allCases { XCTAssertEqual(CareModule(category: c), expected[c], "\(c)") }
    }

    func testTierSplitPerModule() async throws {
        let events = try await CareKit.run([
            FakeStage.spec(.rules, modules: [.aiTools, .worktrees, .modelsDocker, .systemJunk], items: [
                CareKit.item("/f/a", tier: .safe, size: 10),
                CareKit.item("/f/b", tier: .review, size: 20),
                CareKit.item("/f/c", tier: .keep, size: 40),
                CareKit.item("/f/w", tier: .safe, size: 5, category: .worktree),
            ]),
        ])
        let report = try XCTUnwrap(CareKit.report(events))
        let ai = try XCTUnwrap(report.summaries[.aiTools])
        XCTAssertEqual([ai.safeBytes, ai.reviewBytes, ai.keepBytes], [10, 20, 40])
        XCTAssertEqual(ai.itemCount, 3)
        XCTAssertEqual(ai.totalBytes, 70)
        XCTAssertEqual(report.summaries[.worktrees]?.safeBytes, 5)
        XCTAssertEqual(report.totals.totalBytes, 75)
        XCTAssertEqual(report.totals.itemCount, 4)
        // stageFinished carries every module the stage covers, including empty ones.
        guard case .stageFinished(_, let summaries)? = events.first(where: { if case .stageFinished = $0 { true } else { false } }) else {
            return XCTFail("no stageFinished")
        }
        XCTAssertEqual(summaries.map(\.module), [.aiTools, .worktrees, .modelsDocker, .systemJunk])
        XCTAssertEqual(summaries.last?.itemCount, 0)
    }

    func testHardLinksCountOnceInTotals() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("care-hl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a.bin").path, b = dir.appendingPathComponent("b.bin").path
        try Data(count: 64).write(to: URL(fileURLWithPath: a))
        try FileManager.default.linkItem(atPath: a, toPath: b)
        let events = try await CareKit.run([
            FakeStage.spec(.rules, modules: [.aiTools], items: [
                CareKit.item(a, tier: .safe, size: 4_000), CareKit.item(b, tier: .safe, size: 4_000)]),
        ])
        let report = try XCTUnwrap(CareKit.report(events))
        XCTAssertEqual(report.totals.safeBytes, 4_000)
    }

    func testSamePhysicalFileCountsOncePerModuleButOnceInTotals() async throws {
        let model = "/f/models/big.gguf"
        let events = try await CareKit.run([
            FakeStage.spec(.rules, modules: [.modelsDocker], items: [
                CareKit.item(model, tier: .review, size: 4_000, category: .modelWeights, tool: "llama", rule: "m.gguf")]),
            FakeStage.spec(.index, artifact: .tree(CareKit.syntheticTree())),
            FakeStage.spec(.largeOld, modules: [.largeOld], needsTree: true, items: [
                CareKit.item(model, tier: .review, size: 4_000, category: .largeFile, tool: .files, rule: "large.x")]),
        ])
        let report = try XCTUnwrap(CareKit.report(events))
        XCTAssertEqual(report.summaries[.modelsDocker]?.totalBytes, 4_000)
        XCTAssertEqual(report.summaries[.largeOld]?.totalBytes, 4_000)
        XCTAssertEqual(report.totals.totalBytes, 4_000, "counted once, under the first stage")
        XCTAssertEqual(report.totals.itemCount, 1)
        // Both stages still deliver the item to the UI.
        XCTAssertEqual(CareKit.trace(events).filter { $0.hasPrefix("item:") }, ["item:rules", "item:largeOld"])
    }

    func testNestedItemIsNotCountedAgainInTotals() async throws {
        let events = try await CareKit.run([
            FakeStage.spec(.rules, modules: [.worktrees], items: [
                CareKit.item("/f/proj", tier: .review, size: 1_000, category: .worktree)]),
            FakeStage.spec(.index, artifact: .tree(CareKit.syntheticTree())),
            FakeStage.spec(.largeOld, modules: [.largeOld], needsTree: true, items: [
                CareKit.item("/f/proj/big.bin", tier: .review, size: 300, category: .largeFile, tool: .files)]),
        ])
        let report = try XCTUnwrap(CareKit.report(events))
        XCTAssertEqual(report.totals.totalBytes, 1_000)
        XCTAssertEqual(report.summaries[.largeOld]?.totalBytes, 300)
    }

    func testSharedStorageDuplicateCountsZeroAndKeeperIsNotCounted() async throws {
        let events = try await CareKit.run([
            FakeStage.spec(.index, artifact: .tree(CareKit.syntheticTree())),
            FakeStage.spec(.duplicates, modules: [.duplicates], needsTree: true, items: [
                CareKit.item("/f/d/keep", tier: .review, size: 500, category: .duplicate, tool: .files, flags: [.suggestedKeeper]),
                CareKit.item("/f/d/copy1", tier: .review, size: 500, category: .duplicate, tool: .files),
                CareKit.item("/f/d/clone", tier: .review, size: 500, category: .duplicate, tool: .files, flags: [.sharedStorage]),
            ]),
        ])
        let report = try XCTUnwrap(CareKit.report(events))
        XCTAssertEqual(report.summaries[.duplicates]?.reviewBytes, 500)
        XCTAssertEqual(report.summaries[.duplicates]?.itemCount, 2)
        XCTAssertEqual(report.totals.reviewBytes, 500)
    }

    func testNeverRetiers() async throws {
        let events = try await CareKit.run([
            FakeStage.spec(.apps, modules: [.apps], items: [
                CareKit.item("/f/App.app", tier: .review, size: 7, category: .application, tool: .apps)]),
        ])
        let report = try XCTUnwrap(CareKit.report(events))
        XCTAssertEqual(report.summaries[.apps]?.reviewBytes, 7)
        XCTAssertEqual(report.totals.safeBytes, 0)
    }

    /// A later stage's item that CONTAINS an earlier-counted item: the union is counted once.
    func testParentAfterChildCountsOnlyTheRemainder() async throws {
        let events = try await CareKit.run([
            FakeStage.spec(.rules, modules: [.systemJunk], items: [
                CareKit.item("/f/Logs/Claude/a.log", tier: .safe, size: 300, category: .systemJunk)]),
            FakeStage.spec(.apps, modules: [.apps], items: [
                CareKit.item("/f/Logs/Claude", tier: .review, size: 1_000, category: .appLeftover),
                CareKit.item("/f/Logs/Claude/other.log", tier: .review, size: 50, category: .appLeftover)]),
        ])
        let report = try XCTUnwrap(CareKit.report(events))
        XCTAssertEqual(report.totals.totalBytes, 1_000)
        XCTAssertEqual(report.totals.safeBytes, 300)
        XCTAssertEqual(report.totals.reviewBytes, 700, "parent minus the child already counted; a later item inside the parent adds nothing")
        XCTAssertEqual(report.summaries[.apps]?.reviewBytes, 1_050, "module summaries stay undeduplicated")
    }
}
