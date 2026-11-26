import DiskKeeperCore
import XCTest
@testable import AIDiskKeeperUI

final class DuplicateCopyReasonsTests: XCTestCase {
    private let home = DupUI.home

    private func reasons(_ path: String, extra: [DuplicateMember] = []) -> [CopyReason] {
        let keeper = DupUI.member("\(home)/Documents/keep.bin", inode: 1, created: 100)
        let m = DupUI.member(path, inode: 9, created: 100)
        let g = DupUI.group("h", [keeper, m] + extra)
        return DuplicateCopyReasons.reasons(for: m, in: g, rule: .oldest, isManualKeeper: false, home: home)
    }

    func testCopyNamesEnglishAndVietnamese() {
        for name in ["report copy.pdf", "report copy 2.pdf", "report (1).pdf", "report - Copy.pdf", "report_copy.pdf",
                     "report 2.pdf", "báo cáo bản sao.pdf", "báo cáo bản sao 3.pdf", "REPORT COPY.pdf"] {
            XCTAssertTrue(DuplicateCopyReasons.hasCopyInName("/x/\(name)"), name)
        }
        for name in ["report.pdf", "copyright.pdf", "copy of report.pdf", "report-final.pdf", "photo 1.pdf", "invoice-2024.pdf", "report-v2.pdf", "report-2.pdf", "report 2024.pdf"] {
            XCTAssertFalse(DuplicateCopyReasons.hasCopyInName("/x/\(name)"), name)
        }
    }

    func testDashNumberNeedsSiblingWithoutSuffix() {
        let sibs = ["/a/invoice.pdf", "/b/invoice-2.pdf", "/c/report-2.pdf", "/c/invoice-2024.pdf"]
        XCTAssertTrue(DuplicateCopyReasons.hasCopyInName("/b/invoice-2.pdf", siblingPaths: sibs))
        XCTAssertFalse(DuplicateCopyReasons.hasCopyInName("/c/report-2.pdf", siblingPaths: sibs))
        XCTAssertFalse(DuplicateCopyReasons.hasCopyInName("/c/invoice-2024.pdf", siblingPaths: sibs))
        XCTAssertFalse(DuplicateCopyReasons.hasCopyInName("/a/invoice.pdf", siblingPaths: sibs))
        XCTAssertFalse(DuplicateCopyReasons.hasCopyInName("/c/report-v2.pdf", siblingPaths: ["/c/report.pdf"]))
        XCTAssertFalse(DuplicateCopyReasons.hasCopyInName("/b/invoice-2.txt", siblingPaths: sibs))
    }

    func testCloneChipFollowsCurrentKeeper() {
        let original = DupUI.member("\(home)/a.bin", inode: 1, created: 100)
        let clone = DupUI.member("\(home)/b.bin", inode: 2, all: true, created: 200)
        let g = DupUI.group("m", [original, clone])
        XCTAssertEqual(DuplicateCopyReasons.reasons(for: clone, in: g, rule: .oldest, isManualKeeper: false, home: home)
            .first, .cloneOfKept)
        XCTAssertFalse(DuplicateCopyReasons.reasons(for: original, in: g, rule: .oldest, isManualKeeper: false, home: home)
            .contains(.cloneOfKept))
        let swapped = g.reordered(keeper: clone.path)!
        let orig2 = DupUI.member("\(home)/a.bin", inode: 1, shares: true, created: 100)
        let g2 = DupUI.group("m", [clone, orig2])
        XCTAssertTrue(DuplicateCopyReasons.reasons(for: orig2, in: g2, rule: .oldest, isManualKeeper: true, home: home)
            .contains(.cloneOfKept))
        XCTAssertEqual(swapped.keeper.path, clone.path)
    }

    func testLocationReasons() {
        XCTAssertEqual(reasons("\(home)/Downloads/a.bin"), [.inDownloads])
        XCTAssertEqual(reasons("\(home)/Desktop/a.bin"), [.onDesktop])
        XCTAssertEqual(reasons("\(home)/Projects/Old/a.bin"), [.inOldFolder])
        XCTAssertEqual(reasons("\(home)/Backup/x/a.bin"), [.inOldFolder])
        XCTAssertEqual(reasons("\(home)/Documents/a.bin"), [])
        XCTAssertEqual(reasons("\(home)/Downloads2/a.bin"), [])
    }

    func testPriorityPutsSharedFirstAndCapsAtThree() {
        let keeper = DupUI.member("\(home)/Documents/keep.bin", inode: 1, created: 100)
        let clone = DupUI.member("\(home)/Downloads/Old/report copy.bin", inode: 9, all: true, links: ["/a", "/b"], created: 5000)
        let g = DupUI.group("i", [keeper, clone])
        let r = DuplicateCopyReasons.reasons(for: clone, in: g, rule: .oldest, isManualKeeper: false, home: home)
        XCTAssertEqual(r.count, DuplicateCopyReasons.maxChips)
        XCTAssertEqual(r, [.cloneOfKept, .hardLinks(2), .copyInName])
    }

    func testPartlySharedAndAdded() {
        let keeper = DupUI.member("\(home)/a.bin", inode: 1, created: 100)
        let partial = DupUI.member("\(home)/b.bin", inode: 2, reclaimable: 10, shares: true, created: 5000)
        let g = DupUI.group("j", [keeper, partial])
        let r = DuplicateCopyReasons.reasons(for: partial, in: g, rule: .oldest, isManualKeeper: false, home: home)
        XCTAssertEqual(r, [.partlyShared, .added(partial.created)])
    }

    func testKeeperReasons() {
        let keeper = DupUI.member("\(home)/a.bin", inode: 1, git: true, created: 100)
        let other = DupUI.member("\(home)/b.bin", inode: 2, created: 200)
        let g = DupUI.group("k", [keeper, other])
        XCTAssertEqual(DuplicateCopyReasons.reasons(for: keeper, in: g, rule: .oldest, isManualKeeper: false, home: home),
                       [.keeperRule(.oldest), .keeperInGit])
        XCTAssertEqual(DuplicateCopyReasons.reasons(for: keeper, in: g, rule: .insideGitRepo, isManualKeeper: false, home: home),
                       [.keeperRule(.insideGitRepo)])
        XCTAssertEqual(DuplicateCopyReasons.reasons(for: keeper, in: g, rule: .shortestPath, isManualKeeper: true, home: home),
                       [.keeperManual, .keeperInGit])
    }

    func testCopyTextExistsInBothLanguages() {
        let all: [CopyReason] = [.cloneOfKept, .partlyShared, .hardLinks(2), .copyInName, .inDownloads, .onDesktop,
                                 .inOldFolder, .added(Date()), .keeperRule(.oldest), .keeperRule(.insideGitRepo),
                                 .keeperRule(.shortestPath), .keeperInGit, .keeperManual]
        for lang in [AppLanguage.en, .vi] {
            L10n.withLanguage(lang) {
                for r in all {
                    let t = DuplicatesCopy.reason(r)
                    XCTAssertFalse(t.isEmpty)
                    XCTAssertFalse(t.hasPrefix("dup."), "missing key for \(r) in \(lang)")
                }
            }
        }
        L10n.withLanguage(.vi) { XCTAssertEqual(DuplicatesCopy.reason(.keeperManual), "do bạn chọn") }
        L10n.withLanguage(.en) { XCTAssertEqual(DuplicatesCopy.reason(.inDownloads), "in Downloads") }
    }

    func testExplanationsInBothLanguages() {
        let g = DupUI.plain("l", count: 2)
        let clone = DupUI.group("m", [DupUI.member("/h/a", inode: 1), DupUI.member("/h/b", inode: 2, all: true)])
        L10n.withLanguage(.en) {
            XCTAssertTrue(DuplicatesCopy.explanation(for: g.members[1], in: g).contains("keeps \(g.keeper.path)"))
            XCTAssertTrue(DuplicatesCopy.explanation(for: g.keeper, in: g).contains("stays"))
            XCTAssertTrue(DuplicatesCopy.explanation(for: clone.members[1], in: clone).contains("frees nothing"))
        }
        L10n.withLanguage(.vi) {
            XCTAssertTrue(DuplicatesCopy.explanation(for: g.members[1], in: g).contains("Thùng rác"))
            XCTAssertTrue(DuplicatesCopy.explanation(for: g.keeper, in: g).contains("được giữ"))
            XCTAssertTrue(DuplicatesCopy.explanation(for: clone.members[1], in: clone).contains("không giải phóng"))
        }
    }
}
