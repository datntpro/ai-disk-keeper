import DiskKeeperCore
import XCTest
@testable import AIDiskKeeperUI

final class LargeOldCopyTests: XCTestCase {
    func testEnglish() {
        L10n.withLanguage(.en) {
            let f = LargeOldFix.file("Movies/demo.mov", mb: 1200, kind: .video, months: 12)
            let text = LargeOldCopy.explanation(f, now: LargeOldFix.now)
            XCTAssertTrue(text.hasPrefix("Last opened"), text)
            XCTAssertTrue(text.contains("Trash"))
            XCTAssertEqual(LargeOldCopy.count(1), "1 file")
            XCTAssertEqual(LargeOldCopy.sizeFilter(.mb500), "Bigger than 500 MB")
            XCTAssertEqual(LargeOldCopy.ageFilter(.m6), "Not opened for 6 months")
            XCTAssertEqual(LargeOldCopy.ageFilter(.any), "Any age")
            XCTAssertEqual(LargeOldCopy.folderFilter("Home"), "In Home")
            XCTAssertEqual(LargeOldCopy.kindPlural(.diskImageOrInstaller), "Disk images & installers")
            let inst = LargeOldFix.file("Downloads/X.dmg", mb: 700, kind: .diskImageOrInstaller, match: "Xcode")
            XCTAssertTrue(LargeOldCopy.explanation(inst, now: LargeOldFix.now).contains("already in Applications"))
            let shared = LargeOldFix.file("a.bin", mb: 700, links: 2)
            XCTAssertTrue(LargeOldCopy.explanation(shared, now: LargeOldFix.now).contains("shares all of its storage"))
        }
    }

    func testVietnamese() {
        L10n.withLanguage(.vi) {
            XCTAssertEqual(LargeOldCopy.title, "Tệp lớn & cũ")
            XCTAssertEqual(LargeOldCopy.sourceLabel(.spotlight), "Mở lần cuối (Spotlight)")
            XCTAssertEqual(LargeOldCopy.kindPlural(.archive), "Tệp nén")
            XCTAssertEqual(LargeOldCopy.count(1), "1 tệp")
            XCTAssertTrue(LargeOldCopy.count(3).hasSuffix("tệp"))
            XCTAssertTrue(LargeOldCopy.ageFilter(.m6).hasPrefix("Không mở trong"))
            let f = LargeOldFix.file("a.mov", mb: 900, kind: .video)
            XCTAssertTrue(LargeOldCopy.explanation(f, now: LargeOldFix.now).contains("Thùng rác"))
        }
    }

    func testSourceSymbolAndLabelMapping() {
        XCTAssertEqual(LargeOldCopy.sourceSymbol(.spotlight), "magnifyingglass")
        XCTAssertEqual(LargeOldCopy.sourceSymbol(.accessed), "eye")
        XCTAssertEqual(LargeOldCopy.sourceSymbol(.modified), "pencil")
        L10n.withLanguage(.en) {
            XCTAssertEqual(LargeOldCopy.sourceLabel(.accessed), "Last accessed")
            XCTAssertEqual(LargeOldCopy.sourceLabel(.modified), "Last modified")
            let f = LargeOldFix.file("a.bin", mb: 700, source: .accessed)
            XCTAssertTrue(LargeOldCopy.lastOpenedA11y(f, now: LargeOldFix.now).hasPrefix("Last accessed:"))
        }
    }
}
