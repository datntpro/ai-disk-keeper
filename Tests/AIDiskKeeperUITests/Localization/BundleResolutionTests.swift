import XCTest
@testable import AIDiskKeeperUI

final class BundleResolutionTests: XCTestCase {
    func testSystemLanguageSelection() {
        XCTAssertEqual(L10n.resolve(.system, preferred: ["vi-VN", "en-VN"]).language, "vi")
        XCTAssertEqual(L10n.resolve(.system, preferred: ["fr-FR"]).language, "en")
        XCTAssertEqual(L10n.resolve(.system, preferred: ["en-GB"]).language, "en")
        XCTAssertEqual(L10n.resolve(.system, preferred: ["fr-FR", "vi"]).language, "vi")
        XCTAssertEqual(L10n.resolve(.vi, preferred: ["en-US"]).language, "vi")
        XCTAssertEqual(L10n.resolve(.en, preferred: ["vi-VN"]).language, "en")
    }

    func testCatalogCompiledForBothLanguages() {
        XCTAssertTrue(Set(L10n.availableLanguages).isSuperset(of: ["en", "vi"]), "\(L10n.availableLanguages)")
    }

    func testLookupFollowsActiveLanguage() {
        L10n.withLanguage(.vi) { XCTAssertEqual(loc("tier.safe.label", "Safe"), "An toàn") }
        L10n.withLanguage(.en) { XCTAssertEqual(loc("tier.safe.label", "Safe"), "Safe") }
    }

    func testMissingKeyReturnsDefaultValue() {
        L10n.withLanguage(.vi) { XCTAssertEqual(loc("does.not.exist", "Fallback text"), "Fallback text") }
    }

    func testInterpolatedNumbersUseTheAppLanguageNotTheSystemRegion() {
        L10n.withLanguage(.en) { XCTAssertEqual(loc("overview.itemCount", "\(1234) items"), "1,234 items") }
        L10n.withLanguage(.vi) {
            XCTAssertEqual(loc("overview.itemCount", "\(1234) items").replacingOccurrences(of: "\u{00A0}", with: " "), "1.234 mục")
        }
    }

    func testEveryCatalogLanguageLoadsAnEnglishAndVietnameseBundle() {
        for lang in ["en", "vi"] {
            XCTAssertNotNil(Bundle.module.path(forResource: lang, ofType: "lproj"), lang)
        }
    }
}
