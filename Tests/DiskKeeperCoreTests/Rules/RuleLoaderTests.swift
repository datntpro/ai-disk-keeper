import XCTest
@testable import DiskKeeperCore

final class RuleLoaderTests: XCTestCase {
    private var tmp: TemporaryDirectory!
    private var env: PathEnvironment!

    override func setUpWithError() throws {
        tmp = try TemporaryDirectory()
        env = RuleFixtures.environment(tmp)
    }

    override func tearDown() { tmp = nil }

    private func valid(_ tool: String, id: String? = nil) -> String {
        RuleFixtures.file(tool: tool, rules: [RuleFixtures.rule(id: id ?? "\(tool).r", paths: #"["~/.\#(tool)/cache"]"#)])
    }

    private func write(_ dir: String, _ name: String, _ content: String) throws {
        try tmp.file("\(dir)/\(name)", contents: Data(content.utf8))
    }

    private func loader(bundled: Bool = false, user: Bool = true) -> RuleLoader {
        RuleFixtures.loader(env,
                            bundled: bundled ? tmp.url.appendingPathComponent("bundled") : nil,
                            user: user ? tmp.url.appendingPathComponent("user") : nil)
    }

    func testLoadsValidUserRules() throws {
        try write("user", "a.json", valid("a"))
        let r = loader().load()
        XCTAssertTrue(r.errors.isEmpty, "\(r.errors)")
        XCTAssertEqual(r.ruleSets.count, 1)
        XCTAssertEqual(r.ruleSets[0].source, .user)
        XCTAssertEqual(r.allRules.map(\.rule.id), ["a.r"])
        XCTAssertEqual(r.allRules[0].expandedPaths, [env.home + "/.a/cache"])
        XCTAssertEqual(r.allRules[0].tool, "a")
    }

    func testBadFileDoesNotBlockOthers() throws {
        try write("user", "1.json", valid("a"))
        try write("user", "2.json", #"{"schemaVersion":1,"tool":{"id":"b","name":"B"},"rules":[],"x":1}"#)
        try write("user", "3.json", valid("c"))
        let r = loader().load()
        XCTAssertEqual(r.ruleSets.map(\.tool.id.rawValue), ["a", "c"])
        XCTAssertEqual(r.errors.count, 1)
        XCTAssertEqual(r.errors[0].file?.lastPathComponent, "2.json")
        XCTAssertEqual(r.errors[0].kind, .unknownKey)
        XCTAssertEqual(r.errors[0].source, .user)
    }

    func testAllOrNothingPerFile() throws {
        let good = RuleFixtures.rule(id: "a.good", paths: #"["~/.a/x"]"#)
        let bad = RuleFixtures.rule(id: "a.bad", paths: #"["~/.ssh"]"#)
        try write("user", "a.json", RuleFixtures.file(tool: "a", rules: [good, bad]))
        let r = loader().load()
        XCTAssertTrue(r.ruleSets.isEmpty)
        XCTAssertEqual(r.errors.map(\.kind), [.protectedPathTarget])
        XCTAssertEqual(r.errors[0].jsonPath, "rules[1].paths[0]")
    }

    func testDuplicateRuleIDLaterFileRejected() throws {
        try write("bundled", "a.json", valid("a"))
        try write("user", "a.json", valid("a"))
        let r = loader(bundled: true).load()
        XCTAssertEqual(r.ruleSets.count, 1)
        XCTAssertEqual(r.ruleSets[0].source, .bundled)
        XCTAssertEqual(r.errors.count, 1)
        XCTAssertEqual(r.errors[0].kind, .duplicateRuleID)
        XCTAssertEqual(r.errors[0].source, .user)
        XCTAssertEqual(r.errors[0].jsonPath, "rules[0].id")
    }

    func testDuplicateRuleIDWithinOneFileRejected() throws {
        try write("user", "a.json", RuleFixtures.file(tool: "a", rules: [
            RuleFixtures.rule(id: "a.r", paths: #"["~/.a/1"]"#), RuleFixtures.rule(id: "a.r", paths: #"["~/.a/2"]"#)]))
        let r = loader().load()
        XCTAssertTrue(r.ruleSets.isEmpty)
        XCTAssertEqual(r.errors.first?.jsonPath, "rules[1].id")
    }

    func testMissingUserDirIsNotAnError() {
        let r = loader().load()
        XCTAssertTrue(r.errors.isEmpty)
        XCTAssertTrue(r.ruleSets.isEmpty)
        XCTAssertTrue(RuleFixtures.loader(env).load().errors.isEmpty)
    }

    func testUnreadableDirectoryReported() throws {
        try tmp.file("user", contents: Data())   // a file where a directory is expected
        let r = loader().load()
        XCTAssertEqual(r.errors.map(\.kind), [.unreadableDirectory])
    }

    func testNonJSONAndHiddenFilesIgnored() throws {
        try write("user", "README.md", "# hi")
        try write("user", ".x.json", "garbage")
        try write("user", "a.json.bak", "garbage")
        try tmp.dir("user/sub.json")
        try write("user", "ok.json", valid("a"))
        let r = loader().load()
        XCTAssertTrue(r.errors.isEmpty, "\(r.errors)")
        XCTAssertEqual(r.ruleSets.count, 1)
    }

    func testSymlinkPolicy() throws {
        try write("elsewhere", "t.json", valid("a"))
        try tmp.symlink("user/link.json", to: tmp.path("elsewhere/t.json"))
        try tmp.symlink("bundled/link.json", to: tmp.path("elsewhere/t.json"))
        XCTAssertEqual(loader(bundled: false).load().ruleSets.count, 1)      // followed in the user dir
        let b = RuleFixtures.loader(env, bundled: tmp.url.appendingPathComponent("bundled")).load()
        XCTAssertTrue(b.ruleSets.isEmpty)                                    // skipped in the bundled dir
        XCTAssertTrue(b.errors.isEmpty)
    }

    func testFileTooLarge() throws {
        let pad = String(repeating: " ", count: 1_048_576 + 1)
        try write("user", "big.json", valid("a") + pad)
        let r = loader().load()
        XCTAssertEqual(r.errors.map(\.kind), [.fileTooLarge])
        XCTAssertTrue(r.ruleSets.isEmpty)
        try write("user", "exact.json", valid("b") + String(repeating: " ", count: 1_048_576 - valid("b").utf8.count))
        XCTAssertEqual(loader().load().ruleSets.count, 1)
    }

    func testTooManyFiles() throws {
        for i in 0..<201 { try write("user", String(format: "r%03d.json", i), valid("t\(i)")) }
        let r = loader().load()
        XCTAssertEqual(r.ruleSets.count, 200)
        XCTAssertEqual(r.errors.map(\.kind), [.tooManyFiles])
    }

    func testGuardFactoryThrowingFailsClosed() throws {
        try write("user", "a.json", valid("a"))
        try write("user", "b.json", RuleFixtures.file(tool: "b", protect: #"["/tmp/THROW"]"#, rules: [RuleFixtures.rule(id: "b.r")]))
        let r = loader().load()
        XCTAssertTrue(r.ruleSets.isEmpty)
        XCTAssertEqual(r.errors.map(\.kind), [.guardUnavailable])
        XCTAssertNil(r.errors[0].file)
    }

    func testGuardSeesOnlyAcceptedFilesPatterns() throws {
        let rec = PatternRecorder()
        try write("user", "a.json", RuleFixtures.file(tool: "a", protect: #"["~/.pa/**"]"#, rules: [RuleFixtures.rule(id: "a.r")]))
        try write("user", "b.json", RuleFixtures.file(tool: "b", protect: #"["~/.pb/**"]"#, rules: []))   // invalid: no rules
        _ = RuleFixtures.loader(env, user: tmp.url.appendingPathComponent("user"), recorder: rec).load()
        XCTAssertEqual(rec.calls, [[env.home + "/.pa/**"]])
    }

    func testUnavailableEnvPathIsNotAnError() throws {
        let r = RuleFixtures.rule(paths: #"["${HF_HOME}/hub", "~/.t/x"]"#)
        try write("user", "a.json", RuleFixtures.file(rules: [r]))
        let res = loader().load()
        XCTAssertTrue(res.errors.isEmpty, "\(res.errors)")
        XCTAssertEqual(res.allRules[0].expandedPaths, [env.home + "/.t/x"])
        XCTAssertEqual(res.allRules[0].unavailablePaths, [UnavailablePath(template: "${HF_HOME}/hub", reason: "HF_HOME is not set")])
    }

    func testDeterministicOrder() throws {
        for name in ["c", "a", "b"] { try write("user", "\(name).json", valid(name)) }
        for name in ["z", "y"] { try write("bundled", "\(name).json", valid(name)) }
        let first = loader(bundled: true).load()
        XCTAssertEqual(first.ruleSets.map(\.tool.id.rawValue), ["y", "z", "a", "b", "c"])
        for _ in 0..<5 { XCTAssertEqual(loader(bundled: true).load().ruleSets.map(\.file), first.ruleSets.map(\.file)) }
    }

    func testBundledRulesDirectoryLoadsCleanly() {
        // CoreResources, not Bundle.module: that is how this repo locates its resource bundle.
        let r = RuleLoader(environment: env, bundledRulesDirectory: CoreResources.rulesDirectoryURL,
                           guardFactory: RuleFixtures.guardFactory(env: env)).load()
        XCTAssertNotNil(CoreResources.rulesDirectoryURL)
        XCTAssertTrue(r.errors.isEmpty, "\(r.errors)")
    }

    func testDocExamplesLoadThroughLoader() throws {
        for (i, ex) in RuleFixtures.docExamples.enumerated() {
            try write("user", "ex\(i).json", ex.json)
        }
        let r = loader().load()
        XCTAssertTrue(r.errors.isEmpty, "\(r.errors)")
        XCTAssertEqual(r.ruleSets.count, RuleFixtures.docExamples.count)
        XCTAssertTrue(r.protectPatterns.contains(env.home + "/.claude/skills/**"))
    }
}
