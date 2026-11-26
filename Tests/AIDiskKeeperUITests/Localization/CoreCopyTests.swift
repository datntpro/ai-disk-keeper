import DiskKeeperCore
import XCTest
@testable import AIDiskKeeperUI

/// Every Core-originated code must have wording in both languages, and Vietnamese must not silently fall back to English.
final class CoreCopyTests: XCTestCase {
    private func both(_ make: () -> String) -> (en: String, vi: String) {
        (L10n.withLanguage(.en, make), L10n.withLanguage(.vi, make))
    }

    private func assertTranslated(_ make: () -> String, _ what: String, line: UInt = #line) {
        let (en, vi) = both(make)
        XCTAssertFalse(en.isEmpty, what, line: line)
        XCTAssertFalse(vi.isEmpty, what, line: line)
        XCTAssertNotEqual(en, vi, "\(what) falls back to English", line: line)
    }

    func testEveryCategoryHasAName() {
        for c in ItemCategory.allCases {
            if c == .docker { XCTAssertEqual(L10n.withLanguage(.vi) { c.uiName }, "Docker"); continue }   // brand allowlist
            assertTranslated({ c.uiName }, "category \(c)")
        }
    }

    func testToolGroupsAndBrands() {
        L10n.withLanguage(.vi) {
            XCTAssertEqual(ToolID.system.uiName, "Hệ thống")
            XCTAssertEqual(ToolID(rawValue: "cursor").uiName, "Cursor")     // brands are not translated
            XCTAssertEqual(ToolID(rawValue: "mystery").uiName, "mystery")
        }
    }

    func testEveryWarningCodeIsWordedInBothLanguages() {
        let codes: [ScanWarning.Code] = [
            .itemCapExceeded(cap: 5000), .pathError(errno: EACCES), .pathError(errno: EPERM), .pathError(errno: ENOTDIR),
            .pathError(errno: EIO), .ruleOverlap(earlierRuleID: "a.b"), .cannotSize(errno: EIO), .cannotSize(errno: nil),
            .ruleFileInvalid(file: "x.json"), .scannerFailed(scannerID: "s"), .itemOverlap(earlierRuleID: "a.b"),
            .settingsUnreadable(backupName: "settings.json.corrupt-1"), .settingsUnreadable(backupName: nil),
            .appSkipped(reason: .noInfoPlist), .appSkipped(reason: .damagedInfoPlist), .appSkipped(reason: .noBundleID), .sizeIncomplete,
        ]
        for code in codes {
            let w = ScanWarning(kind: .other, message: "English message", code: code)
            assertTranslated({ w.uiMessage }, "\(code)")
        }
    }

    func testCareHistoryWarningHasItsOwnCopy() {
        let w = ScanWarning(kind: .other, message: "Care Scan history could not be saved: x",
                            code: .scannerFailed(scannerID: "care-history"))
        XCTAssertEqual(L10n.withLanguage(.en) { w.uiMessage }, "Couldn't save the scan history. Growth won't be shown next time.")
        XCTAssertFalse(L10n.withLanguage(.vi) { w.uiMessage }.contains("care-history"))
        assertTranslated({ w.uiMessage }, "care-history")
    }

    func testWarningWithoutCodeFallsBackToMessage() {
        let w = ScanWarning(kind: .other, message: "plain")
        XCTAssertEqual(L10n.withLanguage(.vi) { w.uiMessage }, "plain")
    }

    func testEveryDenialReasonIsWorded() {
        for r in PathDenial.Reason.allCases {
            assertTranslated({ CoreCopy.denial(reason: r, pattern: nil, whyID: nil) }, "denial \(r)")
        }
        let vi = L10n.withLanguage(.vi) { CoreCopy.denial(reason: .protectedPath, pattern: "~/.ssh", whyID: "credentials") }
        XCTAssertTrue(vi.contains("~/.ssh"))
        XCTAssertTrue(vi.contains("thông tin đăng nhập"), vi)
    }

    func testEveryProtectedReasonHasWording() {
        var ids = Set((ProtectedPaths.builtInAnchored + ProtectedPaths.builtInBasenames).map(\.id))
        ids.formUnion(["system", "filesystem.root", "allowed.root", "protected.by.rule"])
        for id in ids.sorted() {
            XCTAssertNotNil(CoreCopy.protectedWhy(id: id), "no wording for protected reason \(id)")
        }
    }

    func testBlockerSentencesAreWorded() {
        let blockers: [CleanupBlocker] = [
            .keepTier, .notActionable, .methodNotSupported("x"), .protectedPath(.protectedName, message: "m", pattern: ".env", whyID: "environment.secrets"),
            .missing, .isSymlink, .notOwnedByUser(uid: 1), .symlinkInParentChain(resolvedParent: "/p"), .identityChanged,
            .appRunning(bundleID: "com.x"), .appStateUnknown(bundleID: "com.x"), .nestedInAnotherItem(otherItemID: "i"),
            .duplicate, .permanentDeleteDisabled, .sizingFailed("e"),
        ]
        for b in blockers {
            if case .changedSinceScan = b { continue }
            assertTranslated({ CleanupCopy.sentence(for: b, appName: { $0 }) }, b.code)
        }
    }

    func testDisplayNameUsesVietnameseTitleOnlyForSelfRules() throws {
        func rule(_ id: String, kind: String) throws -> ResolvedRule {
            let json = """
            {"schemaVersion":1,"tool":{"id":"t","name":"T"},"rules":[{"id":"\(id)","title":"Base","category":"aiToolData",
            "paths":["~/.t/cache"],"match":{"kind":"\(kind)"},"tier":"safe","explanation":"Base explanation",
            "localized":{"vi":{"title":"Tiêu đề","explanation":"Giải thích"}}}]}
            """
            let f = try JSONDecoder().decode(RuleFile.self, from: Data(json.utf8))
            return ResolvedRule(rule: f.rules[0], tool: ToolID(rawValue: "t"), expandedPaths: [], unavailablePaths: [])
        }
        let idx = RuleTextIndex(rules: [try rule("t.self", kind: "self"), try rule("t.kids", kind: "children")])
        let selfItem = ItemFixtures.item("Base", ruleID: "t.self"), kidItem = ItemFixtures.item("folder-name", ruleID: "t.kids")
        L10n.withLanguage(.vi) {
            XCTAssertEqual(selfItem.uiDisplayName(idx), "Tiêu đề")
            XCTAssertEqual(kidItem.uiDisplayName(idx), "folder-name")      // data, not translated
            XCTAssertEqual(kidItem.uiExplanation(idx), "Giải thích")
        }
        L10n.withLanguage(.en) {
            XCTAssertEqual(selfItem.uiDisplayName(idx), "Base")
            XCTAssertEqual(kidItem.uiExplanation(idx), "Base explanation")
        }
    }

    func testSearchMatchesEnglishAndLocalizedNames() throws {
        // Without an installed index both fall back to the English name, so search by English still works.
        let item = ItemFixtures.item("Conversation transcripts")
        let q = ItemQuery(searchText: "transcripts")
        XCTAssertEqual(q.scoped([item]).count, 1)
    }
}
