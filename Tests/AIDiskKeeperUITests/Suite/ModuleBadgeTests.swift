import DiskKeeperCore
import SwiftUI
import XCTest
@testable import AIDiskKeeperUI

@MainActor
final class ModuleBadgeTests: XCTestCase {
    private let items = [
        ItemFixtures.item("a", category: .aiToolData, tier: .safe, size: 100),
        ItemFixtures.item("b", category: .aiToolData, tier: .review, size: 50),
        ItemFixtures.item("keep", category: .aiToolData, tier: .keep, size: 9_000),
        ItemFixtures.item("wt", category: .worktree, tier: .safe, size: 10),
        ItemFixtures.item("build", category: .buildArtifact, tier: .review, size: 20),
        ItemFixtures.item("m", category: .modelWeights, tier: .review, size: 1_000),
        ItemFixtures.item("d", category: .docker, tier: .safe, size: 500),
        ItemFixtures.item("dk", category: .docker, tier: .keep, size: 7_000),
    ]

    private func badge(_ provider: any ModuleProvider.Type, _ items: [ScanItem]) async -> ModuleBadge? {
        let events: [ScanEvent] = [.finished(ItemFixtures.result(items))]
        let env = AppEnvironment(pathEnvironment: PathEnvironment(home: "/Users/tester", temporaryDirectory: "/tmp"),
                                 makeScanEngine: { FakeScanEngine(.scripted(events)) })
        let scan = ScanViewModel(makeEngine: { FakeScanEngine(.scripted(events)) })
        scan.startScan()
        for _ in 0..<400 where scan.phase != .finished { try? await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(scan.phase, .finished)
        let ctx = ModuleContext(env: env, scan: scan, suite: SuiteModel(env: env), scanSelection: SelectionModel(),
                                list: ItemListModel(), query: .constant(ItemQuery()), inspectedID: .constant(nil))
        return provider.badge(ctx)
    }

    func testListModuleBadgesSumNonKeepItems() async {
        let b_AIToolsModule = await badge(AIToolsModule.self, items)
        XCTAssertEqual(b_AIToolsModule, .bytes(150))
        let b_WorktreesModule = await badge(WorktreesModule.self, items)
        XCTAssertEqual(b_WorktreesModule, .bytes(30))
        let b_ModelsDockerModule = await badge(ModelsDockerModule.self, items)
        XCTAssertEqual(b_ModelsDockerModule, .bytes(1_500))
    }

    func testEmptyScanGivesNoBadge() async {
        let b_AIToolsModule = await badge(AIToolsModule.self, [])
        XCTAssertNil(b_AIToolsModule)
        let b_WorktreesModule = await badge(WorktreesModule.self, [])
        XCTAssertNil(b_WorktreesModule)
        let b_ModelsDockerModule = await badge(ModelsDockerModule.self, [])
        XCTAssertNil(b_ModelsDockerModule)
    }

    func testKeepOnlyGivesNoBadge() {
        XCTAssertNil(ModuleBadge.reclaimable(ScanTotals(items: [items[2]]), categories: [.aiToolData]))
    }

    func testOverviewAndStubsHaveNoBadge() async {
        let b_OverviewModule = await badge(OverviewModule.self, items)
        XCTAssertNil(b_OverviewModule)
        let b_HistoryModule = await badge(HistoryModule.self, items)
        XCTAssertNil(b_HistoryModule)
    }

    func testTextAndAccessibilityText() {
        XCTAssertEqual(ModuleBadge.count(1234).text, Formatting.count(1234))
        XCTAssertEqual(ModuleBadge.bytes(2_000_000).a11yText, "\(Formatting.bytes(2_000_000)) reclaimable")
        XCTAssertEqual(ModuleBadge.count(3).a11yText, "3 items")
        XCTAssertTrue(L10n.withLanguage(.vi) { ModuleBadge.bytes(1_000_000).a11yText }.contains("giải phóng"))
    }
}
