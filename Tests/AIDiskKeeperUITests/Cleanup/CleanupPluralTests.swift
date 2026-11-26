import XCTest
@testable import AIDiskKeeperUI

/// Counts use String Catalog plural variants: never "1 items".
final class CleanupPluralTests: XCTestCase {
    func testEnglishForms() {
        L10n.withLanguage(.en) {
            XCTAssertEqual(CleanupCopy.trioItems(0), "0 items")
            XCTAssertEqual(CleanupCopy.trioItems(1), "1 item")
            XCTAssertEqual(CleanupCopy.trioItems(5), "5 items")
            XCTAssertEqual(CleanupCopy.resultErrors(1), "1 error")
            XCTAssertEqual(CleanupCopy.resultErrors(2), "2 errors")
            XCTAssertEqual(CleanupCopy.rowOtherCopies(1), "+1 other copy")
            XCTAssertEqual(CleanupCopy.rowOtherCopies(3), "+3 other copies")
            XCTAssertEqual(CleanupCopy.resultSummary(items: 1, errors: 1, skipped: 2),
                           "moved to the Trash · 1 item · 1 error · 2 skipped")
        }
    }

    func testVietnameseHasOneForm() {
        L10n.withLanguage(.vi) {
            XCTAssertEqual(CleanupCopy.trioItems(1), "1 mục")
            XCTAssertEqual(CleanupCopy.trioItems(4), "4 mục")
            XCTAssertEqual(CleanupCopy.resultErrors(1), "1 lỗi")
        }
    }
}
