import XCTest
@testable import DiskKeeperCore

/// T49: optional per-rule `localized` translations.
final class RuleLocalizedTests: XCTestCase {
    private let env = PathEnvironment(home: "/H", temporaryDirectory: "/T", variables: [:])

    private func validate(_ localized: String) -> Result<RuleFile, RuleLoadError> {
        let rule = RuleFixtures.rule(extra: #""localized": \#(localized)"#)
        return RuleFixtures.loader(env).validate(data: Data(RuleFixtures.file(rules: [rule]).utf8),
                                                 file: RuleFixtures.fileURL, source: .user)
    }

    private func decoded(_ localized: String, line: UInt = #line) throws -> ScannerRule {
        guard case .success(let f) = validate(localized) else { XCTFail("expected success", line: line); throw CancellationError() }
        return f.rules[0]
    }

    private func assertRejected(_ localized: String, contains: String? = nil, line: UInt = #line) {
        switch validate(localized) {
        case .success: XCTFail("expected failure for \(localized)", line: line)
        case .failure(let e):
            if let contains { XCTAssertTrue(e.description.contains(contains), "\(e)", line: line) }
        }
    }

    func testValidLocalizedDecodes() throws {
        let r = try decoded(#"{"vi": {"title": "Tiêu đề", "explanation": "Giải thích"}, "zh-Hans": {"title": "标题"}}"#)
        XCTAssertEqual(r.localized["vi"]?.title, "Tiêu đề")
        XCTAssertEqual(r.localized["zh-Hans"]?.explanation, nil)
    }

    func testAbsentLocalizedIsEmpty() throws {
        let rule = RuleFixtures.rule()
        guard case .success(let f) = RuleFixtures.loader(env).validate(
            data: Data(RuleFixtures.file(rules: [rule]).utf8), file: RuleFixtures.fileURL, source: .user)
        else { return XCTFail() }
        XCTAssertTrue(f.rules[0].localized.isEmpty)
    }

    func testEnglishIsRejected() {
        assertRejected(#"{"en": {"title": "T"}}"#, contains: "localizedBaseLanguage")
    }

    func testRejectsUnknownInnerKey() { assertRejected(#"{"vi": {"title": "T", "tier": "safe"}}"#) }
    func testRejectsEmptyInnerObject() { assertRejected(#"{"vi": {}}"#) }
    func testRejectsOverLength() {
        assertRejected(#"{"vi": {"title": "\#(String(repeating: "a", count: 81))"}}"#)
        assertRejected(#"{"vi": {"explanation": "\#(String(repeating: "a", count: 1001))"}}"#)
        assertRejected(#"{"vi": {"title": ""}}"#)
    }
    func testRejectsBadLanguageTag() {
        for tag in ["VI", "v", "vi_VN", "vietnamese1", "vi-", "123"] { assertRejected(#"{"\#(tag)": {"title": "T"}}"#) }
    }
    func testRejectsMoreThanSixteenLanguages() {
        let many = (0..<17).map { #""a\#(Character(UnicodeScalar(97 + $0)!))": {"title": "T"}"# }.joined(separator: ",")
        assertRejected("{\(many)}")
    }
    func testRejectsDuplicateLanguageKeys() {
        let rule = RuleFixtures.rule(extra: #""localized": {"vi": {"title": "A"}, "vi": {"title": "B"}}"#)
        guard case .failure(let e) = RuleFixtures.loader(env).validate(
            data: Data(RuleFixtures.file(rules: [rule]).utf8), file: RuleFixtures.fileURL, source: .user)
        else { return XCTFail("expected duplicateKey") }
        XCTAssertEqual(e.kind, .duplicateKey)
    }

    func testFallbackOrder() throws {
        let r = try decoded(#"{"vi": {"title": "Việt", "explanation": "Giải thích vi"}, "vi-VN": {"title": "Việt Nam"}}"#)
        XCTAssertEqual(r.text(for: ["vi-VN"]).title, "Việt Nam")          // exact tag
        XCTAssertEqual(r.text(for: ["vi-VN"]).explanation, "Giải thích vi") // field falls back to the prefix
        XCTAssertEqual(r.text(for: ["vi"]).title, "Việt")                  // prefix
        XCTAssertEqual(r.text(for: ["fr"]).title, "R")                     // English base
        XCTAssertEqual(r.text(for: ["fr"]).explanation, "x")
        XCTAssertEqual(r.text(for: ["fr", "vi"]).title, "Việt")            // next language in the list
    }

    func testPartialEntryKeepsEnglishForTheOtherField() throws {
        let r = try decoded(#"{"vi": {"explanation": "Chỉ giải thích"}}"#)
        XCTAssertEqual(r.text(for: ["vi"]).title, "R")
        XCTAssertEqual(r.text(for: ["vi"]).explanation, "Chỉ giải thích")
    }

    func testEveryBundledRuleHasVietnamese() throws {
        let dir = try XCTUnwrap(CoreResources.rulesDirectoryURL)
        var count = 0
        for name in try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() where name.hasSuffix(".json") {
            let file = try JSONDecoder().decode(RuleFile.self, from: Data(contentsOf: dir.appendingPathComponent(name)))
            for rule in file.rules {
                count += 1
                let vi = rule.localized["vi"]
                XCTAssertNotNil(vi?.title, "\(rule.id) has no vi title")
                XCTAssertNotNil(vi?.explanation, "\(rule.id) has no vi explanation")
                if let t = vi?.title { XCTAssertNotEqual(t, rule.title, "\(rule.id) vi title is still English") }
                if let e = vi?.explanation { XCTAssertNotEqual(e, rule.explanation, "\(rule.id) vi explanation is still English") }
                for s in [vi?.title, vi?.explanation].compactMap({ $0 }) {
                    XCTAssertEqual(s, s.precomposedStringWithCanonicalMapping, "\(rule.id) is not NFC")
                    XCTAssertEqual(s, s.trimmingCharacters(in: .whitespacesAndNewlines), rule.id)
                }
            }
        }
        XCTAssertGreaterThanOrEqual(count, 98)
    }

    func testRuleTextIndex() throws {
        let rule = try decoded(#"{"vi": {"title": "Việt", "explanation": "Giải thích"}}"#)
        let resolved = ResolvedRule(rule: rule, tool: ToolID(rawValue: "t"), expandedPaths: [], unavailablePaths: [])
        let idx = RuleTextIndex(rules: [resolved])
        XCTAssertEqual(idx.title(ruleID: "t.r", languages: ["vi"]), "Việt")
        XCTAssertEqual(idx.explanation(ruleID: "t.r", languages: ["en"]), "x")
        XCTAssertNil(idx.title(ruleID: "unknown", languages: ["vi"]))
        XCTAssertTrue(idx.titleIsItemName(ruleID: "t.r"))      // match.kind == self
        XCTAssertFalse(idx.titleIsItemName(ruleID: "unknown"))
    }
}
