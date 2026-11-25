import XCTest
@testable import DiskKeeperCore

final class RuleDecodingTests: XCTestCase {
    private let env = PathEnvironment(home: "/H", temporaryDirectory: "/T", variables: [:])
    private var loader: RuleLoader { RuleFixtures.loader(env) }

    private func validate(_ json: String) -> Result<RuleFile, RuleLoadError> {
        loader.validate(data: Data(json.utf8), file: RuleFixtures.fileURL, source: .user)
    }

    private func expectError(_ json: String, _ kind: RuleLoadError.Kind, path: String? = nil,
                             contains: String? = nil, line: UInt = #line) {
        switch validate(json) {
        case .success: XCTFail("expected \(kind)", line: line)
        case .failure(let e):
            XCTAssertEqual(e.kind, kind, "\(e)", line: line)
            if let path { XCTAssertEqual(e.jsonPath, path, "\(e)", line: line) }
            if let contains { XCTAssertTrue(e.message.contains(contains), "\(e)", line: line) }
            XCTAssertEqual(e.file, RuleFixtures.fileURL, line: line)
            XCTAssertTrue(e.description.hasPrefix("test.json"), line: line)
        }
    }

    private func decode(_ json: String) throws -> RuleFile {
        try JSONDecoder().decode(RuleFile.self, from: Data(json.utf8))
    }

    func testDecodesEveryDocExample() throws {
        for (name, json) in RuleFixtures.docExamples {
            let file = try decode(json)
            XCTAssertFalse(file.rules.isEmpty, name)
            // Doc examples also pass structural validation under a realistic environment.
            let real = PathEnvironment(home: "/Users/me", temporaryDirectory: "/var/folders/ab/T", variables: [:])
            XCTAssertNil(RuleValidator.validateStructure(file, environment: real, fileURL: nil, source: nil), name)
        }
    }

    func testDuplicateKeysRejected() {
        let r = RuleFixtures.rule()
        expectError(RuleFixtures.file(rules: [r]).replacingOccurrences(of: #""schemaVersion": 1,"#, with: #""schemaVersion": 1, "schemaVersion": 1,"#),
                    .duplicateKey, path: "", contains: "schemaVersion")
        let dupTier = r.replacingOccurrences(of: #""tier": "safe""#, with: #""tier": "review", "tier": "safe""#)
        expectError(RuleFixtures.file(rules: [dupTier]), .duplicateKey, path: "rules[0]", contains: "tier")
        // escaped spelling of the same key counts as a duplicate
        let esc = r.replacingOccurrences(of: #""tier": "safe""#, with: #""tier": "review", "t\u0069er": "safe""#)
        expectError(RuleFixtures.file(rules: [esc]), .duplicateKey, path: "rules[0]")
        let nested = RuleFixtures.rule(match: #"{"kind":"self","kind":"self"}"#)
        expectError(RuleFixtures.file(rules: [nested]), .duplicateKey, path: "rules[0].match")
        // same key in different objects is fine
        XCTAssertNoThrow(try validate(RuleFixtures.file(rules: [r, RuleFixtures.rule(id: "t.q")])).get())
    }

    func testUnknownTopLevelKeyRejected() {
        expectError(#"{"schemaVersion":1,"tool":{"id":"t","name":"T"},"rules":[\#(RuleFixtures.rule())],"bogus":1}"#,
                    .unknownKey, path: "", contains: "bogus")
    }

    func testUnknownNestedKeyRejectedWithPath() {
        let r = RuleFixtures.rule(match: #"{"kind":"self","foo":1}"#)
        expectError(RuleFixtures.file(rules: [r]), .unknownKey, path: "rules[0].match", contains: "foo")
        expectError(#"{"schemaVersion":1,"tool":{"id":"t","name":"T","x":1},"rules":[\#(RuleFixtures.rule())]}"#,
                    .unknownKey, path: "tool")
    }

    func testKeyNotAllowedForMatchKind() {
        expectError(RuleFixtures.file(rules: [RuleFixtures.rule(match: #"{"kind":"self","glob":"*"}"#)]),
                    .unknownKey, path: "rules[0].match", contains: "glob")
        expectError(RuleFixtures.file(rules: [RuleFixtures.rule(match: #"{"kind":"children","marker":".git"}"#)]),
                    .unknownKey, path: "rules[0].match", contains: "marker")
    }

    func testMissingRequiredKey() {
        let r = #"{"id":"t.r","title":"R","category":"aiToolData","paths":["~/.t"],"match":{"kind":"self"},"tier":"safe"}"#
        expectError(RuleFixtures.file(rules: [r]), .missingKey, path: "rules[0]", contains: "explanation")
        expectError(#"{"schemaVersion":1,"tool":{"id":"t","name":"T"}}"#, .missingKey, path: "", contains: "rules")
        expectError(RuleFixtures.file(rules: [RuleFixtures.rule(match: #"{"kind":"find","name":"x","marker":".git"}"#)]),
                    .missingKey, path: "rules[0].match", contains: "maxDepth")
    }

    func testWrongTypes() {
        expectError(RuleFixtures.file(rules: [RuleFixtures.rule(paths: #""~/x""#)]), .typeMismatch, path: "rules[0].paths")
        expectError(RuleFixtures.file(rules: [RuleFixtures.rule(tier: "bogus")]), .invalidValue, path: "rules[0].tier")
        expectError(#"{"schemaVersion":"1","tool":{"id":"t","name":"T"},"rules":[]}"#, .typeMismatch, path: "schemaVersion")
    }

    func testUnsupportedSchemaVersion() {
        expectError(#"{"schemaVersion":2,"tool":{"id":"t","name":"T"},"rules":[\#(RuleFixtures.rule())]}"#,
                    .unsupportedSchemaVersion, path: "schemaVersion")
    }

    func testInvalidJSONSyntax() {
        expectError("{not json", .invalidJSON)
        expectError("", .invalidJSON)
        expectError("// c\n{}", .invalidJSON)
    }

    func testBadGlobRejectedWithPath() {
        let r = RuleFixtures.rule(match: #"{"kind":"children","glob":"[abc"}"#)
        expectError(RuleFixtures.file(rules: [r]), .invalidGlob, path: "rules[0].match.glob", contains: "unclosed")
        let e = RuleFixtures.rule(match: #"{"kind":"children","exclude":["ok","a/b"]}"#)
        expectError(RuleFixtures.file(rules: [e]), .invalidGlob, path: "rules[0].match.exclude[1]")
    }

    func testBadPathTemplateRejectedWithPath() {
        expectError(RuleFixtures.file(rules: [RuleFixtures.rule(paths: #"["~/ok", "/etc/passwd"]"#)]),
                    .invalidPathTemplate, path: "rules[0].paths[1]")
    }

    func testGitStateConditionRejected() {
        let r = RuleFixtures.rule(extra: #""tierWhen":[{"if":{"gitState":"clean"},"tier":"keep"}]"#)
        expectError(RuleFixtures.file(rules: [r]), .invalidValue, path: "rules[0].tierWhen[0].if.gitState",
                    contains: "only available to code scanners")
    }

    func testEmptyConditionAndRangesRejected() {
        for cond in ["{}", #"{"olderThanDays":0}"#, #"{"olderThanDays":4000}"#, #"{"sizeOverMB":-1}"#,
                     #"{"markerExists":"a/b"}"#, #"{"markerExists":".."}"#] {
            let r = RuleFixtures.rule(extra: #""tierWhen":[{"if":\#(cond),"tier":"keep"}]"#)
            expectError(RuleFixtures.file(rules: [r]), .invalidValue, contains: nil)
        }
    }

    func testMatchRanges() {
        for m in [#"{"kind":"children","depth":0}"#, #"{"kind":"children","depth":4}"#,
                  #"{"kind":"find","name":"x","marker":".git","maxDepth":11}"#,
                  #"{"kind":"find","name":"x","marker":"a/b","maxDepth":2}"#] {
            expectError(RuleFixtures.file(rules: [RuleFixtures.rule(match: m)]), .invalidValue)
        }
    }

    func testDefaultsApplied() throws {
        let file = try decode(RuleFixtures.file(rules: [
            RuleFixtures.rule(match: #"{"kind":"children"}"#),
            RuleFixtures.rule(id: "t.s", match: #"{"kind":"find","name":"x","marker":".git","maxDepth":3}"#),
        ]))
        let r = file.rules[0]
        XCTAssertEqual(r.cleanup.method, .trash)
        XCTAssertEqual(r.cleanup.cleanupMethod, .trash)
        XCTAssertEqual(r.match.depth, 1)
        XCTAssertEqual(r.match.glob?.pattern, "*")
        XCTAssertEqual(r.match.type, .any)
        XCTAssertFalse(r.match.includeHidden)
        XCTAssertEqual(r.project, ProjectStrategy.none)
        XCTAssertTrue(r.tierWhen.isEmpty)
        XCTAssertTrue(file.protect.isEmpty)
        let f = file.rules[1].match
        XCTAssertEqual(f.type, .directory)
        XCTAssertTrue(f.prune)
        XCTAssertEqual(f.maxDepth, 3)
    }

    func testToolCommandRequiresCommandAndArguments() throws {
        let ok = RuleFixtures.rule(extra: #""cleanup":{"method":"toolCommand","command":"docker","arguments":["system","prune","{path}"]}"#)
        let file = try decode(RuleFixtures.file(rules: [ok]))
        XCTAssertEqual(file.rules[0].cleanup.cleanupMethod, .toolCommand(command: "docker", arguments: ["system", "prune", "{path}"]))
        for cleanup in [#"{"method":"toolCommand"}"#, #"{"method":"toolCommand","command":"docker"}"#,
                        #"{"method":"toolCommand","arguments":[]}"#] {
            expectError(RuleFixtures.file(rules: [RuleFixtures.rule(extra: #""cleanup":\#(cleanup)"#)]), .missingKey)
        }
        for command in ["/bin/rm", "Docker", "-x", ""] {
            let c = #"{"method":"toolCommand","command":"\#(command)","arguments":[]}"#
            expectError(RuleFixtures.file(rules: [RuleFixtures.rule(extra: #""cleanup":\#(c)"#)]), .invalidValue)
        }
    }

    func testCommandKeyNotAllowedWithTrash() {
        let c = #"{"method":"trash","command":"rm","arguments":[]}"#
        expectError(RuleFixtures.file(rules: [RuleFixtures.rule(extra: #""cleanup":\#(c)"#)]),
                    .unknownKey, path: "rules[0].cleanup", contains: "arguments")
    }

    func testBundleIDAndDocsURL() {
        for bad in ["nodots", "a..b", "a.b c"] {
            let c = #"{"method":"trash","requiresAppQuit":"\#(bad)"}"#
            expectError(RuleFixtures.file(rules: [RuleFixtures.rule(extra: #""cleanup":\#(c)"#)]), .invalidValue)
        }
        expectError(#"{"schemaVersion":1,"tool":{"id":"t","name":"T","docs":"http://x.y"},"rules":[\#(RuleFixtures.rule())]}"#,
                    .invalidValue, path: "tool.docs")
        expectError(#"{"schemaVersion":1,"tool":{"id":"Bad_ID","name":"T"},"rules":[\#(RuleFixtures.rule())]}"#,
                    .invalidValue, path: "tool.id")
    }

    func testLimits() {
        expectError(#"{"schemaVersion":1,"tool":{"id":"t","name":"T"},"rules":[]}"#, .invalidValue, path: "rules")
        expectError(RuleFixtures.file(rules: [RuleFixtures.rule(paths: "[]")]), .invalidValue, path: "rules[0].paths")
        let longTitle = String(repeating: "x", count: 81)
        let r = RuleFixtures.rule().replacingOccurrences(of: #""title": "R""#, with: #""title": "\#(longTitle)""#)
        expectError(RuleFixtures.file(rules: [r]), .invalidValue, path: "rules[0].title")
    }
}
