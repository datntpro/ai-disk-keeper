import DiskKeeperCore
import XCTest
@testable import AIDiskKeeperUI

@MainActor
final class NavigationModelTests: XCTestCase {
    private let all = Set(ModuleID.allCases)

    func testDestinationWithEveryModuleEnabled() {
        let expected: [ItemCategory: SidebarSelection] = [
            .aiToolData: .module(.aiTools), .worktree: .module(.worktrees), .buildArtifact: .module(.worktrees),
            .modelWeights: .module(.modelsDocker), .docker: .module(.modelsDocker), .largeFile: .module(.largeOld),
            .duplicate: .module(.duplicates), .application: .module(.uninstaller), .appLeftover: .module(.uninstaller),
            .startupItem: .module(.startupItems), .systemJunk: .category(.systemJunk),
        ]
        XCTAssertEqual(Set(expected.keys), Set(ItemCategory.allCases))
        for c in ItemCategory.allCases {
            XCTAssertEqual(NavigationModel.destination(for: c, enabled: all), expected[c], "\(c)")
        }
    }

    func testDestinationFallsBackToCategoryWhenModuleDisabled() {
        for c in ItemCategory.allCases {
            XCTAssertEqual(NavigationModel.destination(for: c, enabled: []), .category(c), "\(c)")
        }
    }

    func testShowResetsSearchAddsTierAndInspects() {
        let nav = NavigationModel()
        var query = ItemQuery(scope: .overview, tiers: [.safe], searchText: "zzz")
        var inspected: ScanItem.ID?
        let item = ItemFixtures.item("wt", category: .worktree, tier: .review)
        nav.show(item: item, query: &query, inspectedID: &inspected, enabled: all)
        XCTAssertEqual(nav.selection, .module(.worktrees))
        XCTAssertEqual(query.scope, .module(.worktrees))
        XCTAssertEqual(query.searchText, "")
        XCTAssertEqual(query.tiers, [.safe, .review])
        XCTAssertEqual(inspected, item.id)
    }

    func testShowFallsBackToCategoryWhenModuleIsNotEnabled() {
        let nav = NavigationModel()
        var query = ItemQuery()
        var inspected: ScanItem.ID?
        nav.show(item: ItemFixtures.item("d", category: .duplicate), query: &query, inspectedID: &inspected, enabled: [])
        XCTAssertEqual(nav.selection, .category(.duplicate))
    }
}
