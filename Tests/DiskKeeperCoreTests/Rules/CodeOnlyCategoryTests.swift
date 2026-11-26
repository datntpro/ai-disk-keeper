import XCTest
@testable import DiskKeeperCore

final class CodeOnlyCategoryTests: XCTestCase {
    private var fixture: FixtureHome!
    override func setUpWithError() throws { fixture = try FixtureHome() }
    override func tearDown() { fixture = nil }

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }
    private let codeOnly = ["largeFile", "duplicate", "application", "appLeftover", "startupItem"]

    func testRuleWithCodeOnlyCategoryIsRejected() throws {
        for cat in codeOnly {
            let rule = RuleFixtures.rule(category: cat)
            let loaded = try RuleHarness.loadRules(json: RuleFixtures.file(tool: "t", rules: [rule]), fixture: fixture)
            XCTAssertEqual(loaded.errors.count, 1, cat)
            let e = try XCTUnwrap(loaded.errors.first)
            XCTAssertEqual(e.kind, .invalidValue)
            XCTAssertEqual(e.jsonPath, "rules[0].category")
            XCTAssertTrue(e.message.contains("built-in scanners only"))
        }
    }

    func testSchemaCategoryEnumEqualsRuleCategories() throws {
        let data = try Data(contentsOf: repoRoot.appendingPathComponent("docs/rules.schema.json"))
        let schema = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let defs = try XCTUnwrap(schema["$defs"] as? [String: Any])
        let rule = try XCTUnwrap(defs["rule"] as? [String: Any])
        let props = try XCTUnwrap(rule["properties"] as? [String: Any])
        let cat = try XCTUnwrap(props["category"] as? [String: Any])
        let values = try XCTUnwrap(cat["enum"] as? [String])
        XCTAssertEqual(Set(values), Set(ItemCategory.ruleCategories.map(\.rawValue)))
    }

    func testRulesDocMentionsCodeOnlyCategories() throws {
        let doc = try String(contentsOf: repoRoot.appendingPathComponent("docs/rules.md"), encoding: .utf8)
        for c in codeOnly { XCTAssertTrue(doc.contains("`\(c)`"), c) }
    }
}
