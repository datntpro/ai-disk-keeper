import DiskKeeperCore
import XCTest
@testable import AIDiskKeeperUI

final class ItemQueryModuleScopeTests: XCTestCase {
    private let items = [
        ItemFixtures.item("ai", category: .aiToolData),
        ItemFixtures.item("wt", category: .worktree),
        ItemFixtures.item("build", category: .buildArtifact),
        ItemFixtures.item("model", category: .modelWeights),
    ]

    func testWorktreesModuleListsWorktreeAndBuildArtifactOnly() {
        let q = ItemQuery(scope: .module(.worktrees))
        XCTAssertEqual(Set(q.apply(to: items).map(\.displayName)), ["wt", "build"])
        XCTAssertEqual(q.scoped(items).count, 2)
    }

    func testScreenModuleListsNothing() {
        XCTAssertEqual(ItemQuery(scope: .module(.diskMap)).apply(to: items), [])
        XCTAssertEqual(ItemQuery(scope: .module(.history)).scoped(items), [])
    }

    func testSearchStillAppliesWithinModule() {
        var q = ItemQuery(scope: .module(.worktrees))
        q.searchText = "build"
        XCTAssertEqual(q.apply(to: items).map(\.displayName), ["build"])
    }

    func testTotalsTrackReclaimablePerCategory() {
        let t = ScanTotals(items: [ItemFixtures.item("a", size: 5), ItemFixtures.item("k", tier: .keep, size: 99)])
        XCTAssertEqual(t.byCategory[.aiToolData]?.allocatedBytes, 104)
        XCTAssertEqual(t.reclaimableByCategory[.aiToolData]?.allocatedBytes, 5)
    }
}
