import DiskKeeperCore
import XCTest
@testable import AIDiskKeeperUI

/// F1: a search with no matches must resolve to the filtered-empty state (not a blank table), and the
/// state is judged on the unfiltered scope, not the post-search counts.
@MainActor
final class ScopedListFilteredEmptyTests: XCTestCase {
    private let items = [
        ItemFixtures.item("a", category: .aiToolData, tier: .safe, size: 100),
        ItemFixtures.item("wt", category: .worktree, tier: .safe, size: 10),
        ItemFixtures.item("m", category: .modelWeights, tier: .review, size: 1_000),
    ]

    private func resolve(_ module: ModuleID, search: String, tiers: Set<RiskTier> = Set(RiskTier.allCases)) async -> (ModuleState, ItemListModel) {
        let query = ItemQuery(scope: .module(module), tiers: tiers, searchText: search)
        let list = ItemListModel()
        list.update(items: items, query: query)
        for _ in 0..<400 where list.scopeCount == 0 { try? await Task.sleep(nanoseconds: 5_000_000) }
        let state = ModuleStateResolver.state(hasRun: true, isLoading: false, progress: nil, itemCount: list.scopeCount,
                                              filteredCount: list.rows.count, query: search, warnings: [], error: nil)
        return (state, list)
    }

    func testSearchWithNoResultsIsFilteredEmptyInEachListModule() async {
        for module in [ModuleID.aiTools, .worktrees, .modelsDocker] {
            let (state, list) = await resolve(module, search: "zzz")
            XCTAssertEqual(list.tierCounts.values.reduce(0, +), 0, "post-search counts are 0 for \(module)")
            XCTAssertGreaterThan(list.scopeCount, 0, "scope still has data for \(module)")
            XCTAssertEqual(state, .filteredEmpty(query: "zzz"), "\(module)")
            XCTAssertEqual(ScopedItemListView.filteredEmpty(state, scanning: false)?.title, StateCopy.filteredTitle("zzz"))
        }
    }

    func testMatchingSearchShowsContent() async {
        let (state, _) = await resolve(.aiTools, search: "a")
        XCTAssertEqual(state, .content)
        XCTAssertNil(ScopedItemListView.filteredEmpty(state, scanning: false))
    }

    func testOverlayHiddenWhileScanning() async {
        let (state, _) = await resolve(.aiTools, search: "zzz")
        XCTAssertNil(ScopedItemListView.filteredEmpty(state, scanning: true))
    }

    func testEmptyScopeIsEmptyNotFiltered() async {
        let query = ItemQuery(scope: .module(.aiTools), searchText: "zzz")
        let list = ItemListModel()
        list.update(items: [], query: query)
        try? await Task.sleep(nanoseconds: 50_000_000)
        let state = ModuleStateResolver.state(hasRun: true, isLoading: false, progress: nil, itemCount: list.scopeCount,
                                              filteredCount: 0, query: "zzz", warnings: [], error: nil)
        XCTAssertEqual(state, .empty)
    }
}
