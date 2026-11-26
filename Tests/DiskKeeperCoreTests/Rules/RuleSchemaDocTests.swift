import XCTest
@testable import DiskKeeperCore

/// Catches drift between docs/rules.schema.json, docs/rules.md and the Swift decoders.
final class RuleSchemaDocTests: XCTestCase {
    private var repoRoot: URL {
        // <root>/Tests/DiskKeeperCoreTests/Rules/RuleSchemaDocTests.swift
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    private func loadSchema() throws -> [String: Any] {
        let data = try Data(contentsOf: repoRoot.appendingPathComponent("docs/rules.schema.json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func keys(_ object: [String: Any], file: StaticString = #filePath, line: UInt = #line) -> Set<String> {
        guard let props = object["properties"] as? [String: Any] else {
            XCTFail("no properties", file: file, line: line)
            return []
        }
        XCTAssertEqual(object["additionalProperties"] as? Bool, false, file: file, line: line)
        return Set(props.keys)
    }

    func testSchemaPropertiesMatchSwiftAllowedKeys() throws {
        let schema = try loadSchema()
        let defs = try XCTUnwrap(schema["$defs"] as? [String: Any])
        func def(_ name: String) throws -> [String: Any] { try XCTUnwrap(defs[name] as? [String: Any]) }

        XCTAssertEqual(keys(schema), RuleFile.allowedKeys)
        let tool = try XCTUnwrap((schema["properties"] as? [String: Any])?["tool"] as? [String: Any])
        XCTAssertEqual(keys(tool), ToolInfo.allowedKeys)
        let rule = try def("rule")
        XCTAssertEqual(keys(rule), ScannerRule.allowedKeys)
        XCTAssertEqual(keys(try def("condition")), TierCondition.allowedKeys)
        XCTAssertEqual(keys(try def("cleanup")), RuleCleanup.allowedKeys)

        let tierWhenItems = try XCTUnwrap(((rule["properties"] as? [String: Any])?["tierWhen"] as? [String: Any])?["items"]
                                          as? [String: Any])
        XCTAssertEqual(keys(tierWhenItems), TierWhen.allowedKeys)

        let variants = try XCTUnwrap(try def("match")["oneOf"] as? [[String: Any]])
        XCTAssertEqual(variants.count, MatchKind.allCases.count)
        var union = Set<String>()
        for variant in variants {
            let k = keys(variant)
            let kind = try XCTUnwrap((((variant["properties"] as? [String: Any])?["kind"]) as? [String: Any])?["const"] as? String)
            XCTAssertEqual(k, RuleMatch.allowedKeys(for: try XCTUnwrap(MatchKind(rawValue: kind))), kind)
            union.formUnion(k)
        }
        XCTAssertEqual(union, RuleMatch.allKeys)
    }

    func testSchemaRequiredKeysAndCleanupConditionals() throws {
        let schema = try loadSchema()
        let defs = try XCTUnwrap(schema["$defs"] as? [String: Any])
        XCTAssertEqual(Set(try XCTUnwrap(schema["required"] as? [String])), ["schemaVersion", "tool", "rules"])
        let rule = try XCTUnwrap(defs["rule"] as? [String: Any])
        XCTAssertEqual(Set(try XCTUnwrap(rule["required"] as? [String])),
                       ["id", "title", "category", "paths", "match", "tier", "explanation"])
        let variants = try XCTUnwrap((defs["match"] as? [String: Any])?["oneOf"] as? [[String: Any]])
        XCTAssertEqual(Set(try XCTUnwrap(variants[2]["required"] as? [String])), ["kind", "name", "marker", "maxDepth"])
        let cleanup = try XCTUnwrap(defs["cleanup"] as? [String: Any])
        XCTAssertEqual(try XCTUnwrap(cleanup["required"] as? [String]), ["method"])
        let allOf = try XCTUnwrap(cleanup["allOf"] as? [[String: Any]])
        XCTAssertEqual(allOf.count, 2, "cleanup needs if/then for trash|none and toolCommand")
    }

    func testSchemaEnumsMatchSwiftEnums() throws {
        let defs = try XCTUnwrap(try loadSchema()["$defs"] as? [String: Any])
        let rule = try XCTUnwrap(defs["rule"] as? [String: Any])
        let props = try XCTUnwrap(rule["properties"] as? [String: Any])
        let category = try XCTUnwrap((props["category"] as? [String: Any])?["enum"] as? [String])
        XCTAssertEqual(Set(category), Set(ItemCategory.ruleCategories.map(\.rawValue)))
        let tier = try XCTUnwrap((defs["tier"] as? [String: Any])?["enum"] as? [String])
        XCTAssertEqual(Set(tier), Set(RiskTier.allCases.map(\.rawValue)))
        let from = try XCTUnwrap(((props["project"] as? [String: Any])?["properties"] as? [String: Any])?["from"] as? [String: Any])
        XCTAssertEqual(Set(try XCTUnwrap(from["enum"] as? [String])), Set(ProjectStrategy.allCases.map(\.rawValue)))
        let cleanup = try XCTUnwrap(defs["cleanup"] as? [String: Any])
        let method = try XCTUnwrap(((cleanup["properties"] as? [String: Any])?["method"] as? [String: Any])?["enum"] as? [String])
        XCTAssertEqual(Set(method), Set(RuleCleanup.Method.allCases.map(\.rawValue)))
    }

    func testDocContainsEveryExampleVerbatim() throws {
        let doc = try String(contentsOf: repoRoot.appendingPathComponent("docs/rules.md"), encoding: .utf8)
        for (name, json) in RuleFixtures.docExamples {
            XCTAssertTrue(doc.contains(json), "docs/rules.md is missing the '\(name)' example verbatim")
        }
    }

    func testDocMentionsEveryErrorKind() throws {
        let doc = try String(contentsOf: repoRoot.appendingPathComponent("docs/rules.md"), encoding: .utf8)
        for kind in RuleLoadError.Kind.allCases {
            XCTAssertTrue(doc.contains("`\(kind.rawValue)`"), "docs/rules.md does not document \(kind)")
        }
    }
}
