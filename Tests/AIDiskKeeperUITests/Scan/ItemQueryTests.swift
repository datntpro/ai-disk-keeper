import DiskKeeperCore
import XCTest
@testable import AIDiskKeeperUI

final class ItemQueryTests: XCTestCase {
    private typealias F = ItemFixtures
    private let d1 = Date(timeIntervalSince1970: 1000), d2 = Date(timeIntervalSince1970: 2000)

    private var items: [ScanItem] {
        [F.item("Alpha", tool: .claudeCode, category: .aiToolData, tier: .safe, size: 300, lastModified: d1),
         F.item("beta", tool: .cursor, category: .buildArtifact, tier: .review, size: 100, lastModified: d2),
         F.item("Gamma", tool: .cursor, category: .aiToolData, tier: .keep, size: 300, lastModified: nil)]
    }

    private func names(_ q: ItemQuery) -> [String] { q.apply(to: items).map(\.displayName) }

    func testScopeByToolAndCategory() {
        XCTAssertEqual(Set(names(ItemQuery(scope: .tool(.cursor)))), ["beta", "Gamma"])
        XCTAssertEqual(Set(names(ItemQuery(scope: .category(.aiToolData)))), ["Alpha", "Gamma"])
        XCTAssertEqual(names(ItemQuery(scope: .warnings)), [])
        XCTAssertEqual(names(ItemQuery(scope: .overview)).count, 3)
    }

    func testTierFilter() {
        XCTAssertEqual(names(ItemQuery(tiers: [.review])), ["beta"])
        XCTAssertEqual(names(ItemQuery(tiers: [])), [])
    }

    func testSearchNameAndPathCaseInsensitive() {
        XCTAssertEqual(names(ItemQuery(searchText: "ALPHA")), ["Alpha"])
        XCTAssertEqual(Set(names(ItemQuery(searchText: "/FIXTURE/cursor"))), ["beta", "Gamma"])
    }

    func testSortKeysWithStableTieBreak() {
        // size desc: Alpha and Gamma tie at 300 → by id ascending (Alpha's id sorts before Gamma's)
        XCTAssertEqual(names(ItemQuery(sort: ItemSort(key: .size))), ["Alpha", "Gamma", "beta"])
        XCTAssertEqual(names(ItemQuery(sort: ItemSort(key: .size, ascending: true))), ["beta", "Alpha", "Gamma"])
        XCTAssertEqual(names(ItemQuery(sort: ItemSort(key: .name, ascending: true))), ["Alpha", "beta", "Gamma"])
        XCTAssertEqual(names(ItemQuery(sort: ItemSort(key: .lastUsed))), ["beta", "Alpha", "Gamma"])
        XCTAssertEqual(names(ItemQuery(sort: ItemSort(key: .tier, ascending: true))), ["Alpha", "beta", "Gamma"])
    }

    func testTotals() {
        let t = ItemQuery(tiers: [.safe, .review]).totals(for: items)
        XCTAssertEqual(t.all.allocatedBytes, 400)
        XCTAssertEqual(t.bulkSelectable.itemCount, 1)
    }
}
