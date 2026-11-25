import XCTest
@testable import AIDiskKeeperUI

final class ItemTableSortTests: XCTestCase {
    func testRoundTrip() {
        for key in [ItemSortKey.size, .name, .lastUsed, .tier] {
            for asc in [true, false] {
                let sort = ItemSort(key: key, ascending: asc)
                XCTAssertEqual(ItemTableSort.sort(from: ItemTableSort.comparators(for: sort)), sort)
            }
        }
        XCTAssertNil(ItemTableSort.sort(from: []))
    }

    func testRelativeJustNow() {
        XCTAssertEqual(Formatting.relative(Date().addingTimeInterval(-5)), "just now")
        XCTAssertEqual(Formatting.relative(nil), "—")
    }

    func testUnknownBundleIDFallsBackToID() {
        XCTAssertEqual(AppNameResolver.name(forBundleID: "com.example.not-installed-xyz"), "com.example.not-installed-xyz")
    }
}
