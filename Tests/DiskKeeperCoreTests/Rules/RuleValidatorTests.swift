import XCTest
@testable import DiskKeeperCore

final class RuleValidatorTests: XCTestCase {
    private var tmp: TemporaryDirectory!
    private var env: PathEnvironment!

    override func setUpWithError() throws {
        tmp = try TemporaryDirectory()
        env = RuleFixtures.environment(tmp)
    }

    override func tearDown() { tmp = nil }

    private func load(_ jsons: [String], variables: [String: String] = [:],
                      recorder: PatternRecorder? = nil) throws -> RuleLoadResult {
        var e = env!
        e.variables = variables
        for (i, j) in jsons.enumerated() { try tmp.file("user/f\(i).json", contents: Data(j.utf8)) }
        return RuleFixtures.loader(e, user: tmp.url.appendingPathComponent("user"), recorder: recorder).load()
    }

    private func expectOne(_ r: RuleLoadResult, _ kind: RuleLoadError.Kind, path: String? = nil,
                           line: UInt = #line) {
        XCTAssertEqual(r.errors.count, 1, "\(r.errors)", line: line)
        XCTAssertEqual(r.errors.first?.kind, kind, "\(r.errors)", line: line)
        if let path { XCTAssertEqual(r.errors.first?.jsonPath, path, line: line) }
    }

    func testRuleIDMustBePrefixedByToolID() throws {
        for id in ["other.r", "t.", "t.A", "t.a..b", "t.-a", "t.a-", "t", "ta.b", "t." + String(repeating: "a", count: 100)] {
            expectOne(try load([RuleFixtures.file(rules: [RuleFixtures.rule(id: id)])]), .invalidRuleID, path: "rules[0].id")
            try? FileManager.default.removeItem(at: tmp.url.appendingPathComponent("user"))
        }
        let ok = try load([RuleFixtures.file(rules: [RuleFixtures.rule(id: "t.a-b.c1")])])
        XCTAssertTrue(ok.errors.isEmpty, "\(ok.errors)")
    }

    func testModelWeightsCannotBeSafe() throws {
        expectOne(try load([RuleFixtures.file(rules: [RuleFixtures.rule(category: "modelWeights", tier: "safe")])]),
                  .invalidValue, path: "rules[0].tier")
        try FileManager.default.removeItem(at: tmp.url.appendingPathComponent("user"))
        let r = RuleFixtures.rule(category: "modelWeights", tier: "review",
                                  extra: #""tierWhen":[{"if":{"olderThanDays":5},"tier":"safe"}]"#)
        expectOne(try load([RuleFixtures.file(rules: [r])]), .invalidValue, path: "rules[0].tierWhen[0].tier")
        try FileManager.default.removeItem(at: tmp.url.appendingPathComponent("user"))
        let fine = RuleFixtures.rule(category: "modelWeights", tier: "review",
                                     extra: #""tierWhen":[{"if":{"newerThanDays":5},"tier":"keep"}]"#)
        XCTAssertTrue(try load([RuleFixtures.file(rules: [fine])]).errors.isEmpty)
    }

    func testContradictoryAgeCondition() throws {
        for cond in [#"{"olderThanDays":10,"newerThanDays":5}"#, #"{"olderThanDays":5,"newerThanDays":5}"#] {
            let r = RuleFixtures.rule(extra: #""tierWhen":[{"if":\#(cond),"tier":"keep"}]"#)
            expectOne(try load([RuleFixtures.file(rules: [r])]), .invalidValue, path: "rules[0].tierWhen[0].if")
            try FileManager.default.removeItem(at: tmp.url.appendingPathComponent("user"))
        }
        let ok = RuleFixtures.rule(extra: #""tierWhen":[{"if":{"olderThanDays":5,"newerThanDays":10},"tier":"keep"}]"#)
        XCTAssertTrue(try load([RuleFixtures.file(rules: [ok])]).errors.isEmpty)
    }

    func testAbsolutePathOutsideAllowedRootsRejected() throws {
        let r = RuleFixtures.rule(paths: #"["${X}/y"]"#)
        expectOne(try load([RuleFixtures.file(rules: [r])], variables: ["X": "/etc"]),
                  .pathOutsideAllowedRoots, path: "rules[0].paths[0]")
    }

    func testAliasesAreAcceptedAsRoots() throws {
        let r = RuleFixtures.rule(paths: #"["/tmp/agent", "/private/tmp/agent"]"#)
        XCTAssertTrue(try load([RuleFixtures.file(rules: [r])]).errors.isEmpty)
    }

    func testSiblingOfRootIsOutside() throws {
        // "<home>x" must not be treated as inside "<home>".
        let r = RuleFixtures.rule(paths: #"["${X}/y"]"#)
        expectOne(try load([RuleFixtures.file(rules: [r])], variables: ["X": env.home + "x"]),
                  .pathOutsideAllowedRoots)
    }

    func testRootItselfRejectedForSelf() throws {
        for p in ["~", "$TMPDIR", "/private/tmp", "/tmp"] {
            expectOne(try load([RuleFixtures.file(rules: [RuleFixtures.rule(paths: #"["\#(p)"]"#)])]),
                      .pathOutsideAllowedRoots, path: "rules[0].paths[0]")
            try FileManager.default.removeItem(at: tmp.url.appendingPathComponent("user"))
        }
    }

    func testRootAllowedAsChildrenContainer() throws {
        let r = RuleFixtures.rule(paths: #"["$TMPDIR", "/private/tmp"]"#, match: #"{"kind":"children","glob":"claude-*"}"#)
        let result = try load([RuleFixtures.file(rules: [r])])
        XCTAssertTrue(result.errors.isEmpty, "\(result.errors)")
        XCTAssertEqual(result.allRules.first?.expandedPaths, [env.temporaryDirectory, "/private/tmp"])
    }

    func testContainerOnlyDenialAllowedForChildrenButNotSelf() throws {
        let children = RuleFixtures.rule(paths: #"["~/.claude/projects"]"#, match: #"{"kind":"children","depth":2}"#)
        XCTAssertTrue(try load([RuleFixtures.file(rules: [children])]).errors.isEmpty)
        try FileManager.default.removeItem(at: tmp.url.appendingPathComponent("user"))
        let selfRule = RuleFixtures.rule(paths: #"["~/.claude/projects"]"#)
        expectOne(try load([RuleFixtures.file(rules: [selfRule])]), .protectedPathTarget, path: "rules[0].paths[0]")
    }

    func testProtectedTargetRejected() throws {
        for match in [#"{"kind":"self"}"#, #"{"kind":"children"}"#] {
            let r = try load([RuleFixtures.file(rules: [RuleFixtures.rule(paths: #"["~/.ssh"]"#, match: match)])])
            expectOne(r, .protectedPathTarget, path: "rules[0].paths[0]")
            XCTAssertTrue(r.errors[0].message.contains("protected"), "\(r.errors[0])")
            XCTAssertTrue(r.errors[0].message.contains(".ssh"))
            XCTAssertNotNil(r.errors[0].file)
            XCTAssertTrue(r.ruleSets.isEmpty)
            try FileManager.default.removeItem(at: tmp.url.appendingPathComponent("user"))
        }
    }

    func testProtectedViaRuleOwnProtect() throws {
        let rec = PatternRecorder()
        let file = RuleFixtures.file(protect: #"["~/.foo/**"]"#, rules: [RuleFixtures.rule(paths: #"["~/.foo/cache"]"#)])
        let r = try load([file], recorder: rec)
        expectOne(r, .protectedPathTarget, path: "rules[0].paths[0]")
        XCTAssertEqual(rec.calls, [[env.home + "/.foo/**"]])
    }

    func testProtectFromOneFileAppliesToOthers() throws {
        let a = RuleFixtures.file(tool: "a", protect: #"["~/.shared/**"]"#,
                                  rules: [RuleFixtures.rule(id: "a.r", paths: #"["~/.a/cache"]"#)])
        let b = RuleFixtures.file(tool: "b", rules: [RuleFixtures.rule(id: "b.r", paths: #"["~/.shared/cache"]"#)])
        let r = try load([a, b])
        XCTAssertEqual(r.ruleSets.count, 1)
        XCTAssertEqual(r.ruleSets[0].tool.id, "a")
        expectOne(r, .protectedPathTarget, path: "rules[0].paths[0]")
        XCTAssertEqual(r.errors[0].file?.lastPathComponent, "f1.json")
        XCTAssertEqual(r.protectPatterns, [env.home + "/.shared/**"])
    }

    func testOverbroadProtectPatternsRejected() throws {
        for pattern in ["~", "~/**", "~/*", "$HOME/*", "$TMPDIR", "$TMPDIR/**", "/private/tmp", "/tmp/**", "/tmp",
                        "${X}/**"] {
            let file = RuleFixtures.file(protect: #"["\#(pattern)"]"#, rules: [RuleFixtures.rule()])
            expectOne(try load([file], variables: ["X": env.home]), .invalidProtectPattern, path: "protect[0]")
            try FileManager.default.removeItem(at: tmp.url.appendingPathComponent("user"))
        }
        for pattern in ["~/.foo/**", "~/.claude/settings*.json", "$TMPDIR/keep-*", "/private/tmp/keep/**", "~/.[a-b]x"] {
            let file = RuleFixtures.file(protect: #"["\#(pattern)"]"#, rules: [RuleFixtures.rule()])
            let r = try load([file])
            XCTAssertTrue(r.errors.isEmpty, "\(pattern): \(r.errors)")
            try FileManager.default.removeItem(at: tmp.url.appendingPathComponent("user"))
        }
    }

    func testProtectPatternsAreGlobEscapedAndStillEnforced() throws {
        for home in ["/Users/a[1]", "/Users/a*b", "/Users/a?b", "/Users/a**b"] {
            let rec = PatternRecorder()
            let weird = PathEnvironment(home: home, temporaryDirectory: "/T", variables: [:])
            let file = RuleFixtures.file(protect: #"["~/.foo/**"]"#, rules: [RuleFixtures.rule(paths: #"["~/.foo/cache"]"#)])
            try tmp.file("w/f.json", contents: Data(file.utf8))
            let r = RuleFixtures.loader(weird, user: tmp.url.appendingPathComponent("w"), recorder: rec).load()
            let escaped = home.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "*", with: "\\*")
                .replacingOccurrences(of: "?", with: "\\?").replacingOccurrences(of: "[", with: "\\[")
                .replacingOccurrences(of: "]", with: "\\]") + "/.foo/**"
            XCTAssertEqual(rec.calls, [[escaped]], home)
            XCTAssertEqual(r.protectPatterns, [escaped], home)
            // The rule targets the protected folder, so it must be rejected even with glob chars in home.
            XCTAssertEqual(r.errors.map(\.kind), [.protectedPathTarget], home)
            try FileManager.default.removeItem(at: tmp.url.appendingPathComponent("w"))
        }
    }

    func testProtectPatternsSurviveRejectionOfTheirFile() throws {
        let file = RuleFixtures.file(protect: #"["~/.secret/**"]"#, rules: [RuleFixtures.rule(paths: #"["~/.ssh"]"#)])
        let other = RuleFixtures.file(tool: "o", rules: [RuleFixtures.rule(id: "o.r", paths: #"["~/.secret/cache"]"#)])
        let r = try load([file, other])
        XCTAssertTrue(r.ruleSets.isEmpty)
        XCTAssertEqual(r.errors.map(\.kind), [.protectedPathTarget, .protectedPathTarget])
        XCTAssertEqual(r.protectPatterns, [env.home + "/.secret/**"])
        try FileManager.default.removeItem(at: tmp.url.appendingPathComponent("user"))
        // also when the file is dropped for a duplicate id
        let a = RuleFixtures.file(tool: "d", rules: [RuleFixtures.rule(id: "d.r", paths: #"["~/.d/x"]"#)])
        let b = RuleFixtures.file(tool: "d", protect: #"["~/.keepme/**"]"#, rules: [RuleFixtures.rule(id: "d.r", paths: #"["~/.d/y"]"#)])
        let r2 = try load([a, b])
        XCTAssertEqual(r2.errors.map(\.kind), [.duplicateRuleID])
        XCTAssertEqual(r2.protectPatterns, [env.home + "/.keepme/**"])
    }
}
