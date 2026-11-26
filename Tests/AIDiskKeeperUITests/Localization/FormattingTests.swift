import XCTest
@testable import AIDiskKeeperUI

final class FormattingTests: XCTestCase {
    private let vi = Locale(identifier: "vi_VN"), en = Locale(identifier: "en_US")

    private func norm(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{00A0}", with: " ").replacingOccurrences(of: "\u{202F}", with: " ")
    }

    func testBytes() {
        XCTAssertEqual(norm(Formatting.bytes(1_234_567_890, locale: vi)), "1,23 GB")
        XCTAssertEqual(norm(Formatting.bytes(1_234_567_890, locale: en)), "1.23 GB")
    }

    func testCounts() {
        XCTAssertEqual(norm(Formatting.count(1_234_567, locale: vi)), "1.234.567")
        XCTAssertEqual(norm(Formatting.count(1_234_567, locale: en)), "1,234,567")
    }

    func testRelative() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let twoHours = now.addingTimeInterval(-7200)
        XCTAssertEqual(norm(Formatting.relative(twoHours, now: now, locale: vi)), "2 giờ trước")
        XCTAssertEqual(norm(Formatting.relative(twoHours, now: now, locale: en)), "2 hours ago")
        XCTAssertEqual(Formatting.relative(nil, now: now, locale: vi), "—")
    }

    func testJustNowFollowsTheActiveLanguage() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        L10n.withLanguage(.en) { XCTAssertEqual(Formatting.relative(now.addingTimeInterval(-5), now: now), "just now") }
        L10n.withLanguage(.vi) { XCTAssertEqual(Formatting.relative(now.addingTimeInterval(-5), now: now), "vừa xong") }
    }

    func testAbsoluteDate() {
        let d = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(norm(Formatting.absolute(d, locale: vi)).contains("thg"), Formatting.absolute(d, locale: vi))
        XCTAssertFalse(norm(Formatting.absolute(d, locale: en)).contains("thg"))
        XCTAssertEqual(Formatting.absolute(nil, locale: vi), "—")
    }

    func testDefaultLocaleIsTheAppLanguage() {
        L10n.withLanguage(.vi) { XCTAssertEqual(norm(Formatting.bytes(1_234_567_890)), "1,23 GB") }
        L10n.withLanguage(.en) { XCTAssertEqual(norm(Formatting.bytes(1_234_567_890)), "1.23 GB") }
    }
}
