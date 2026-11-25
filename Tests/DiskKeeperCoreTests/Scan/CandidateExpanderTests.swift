import XCTest
@testable import DiskKeeperCore

final class CandidateExpanderTests: XCTestCase {
    private var fixture: FixtureHome!
    private var restore: [String] = []

    override func setUpWithError() throws { fixture = try FixtureHome() }

    override func tearDown() {
        for p in restore { chmod(p, 0o755) }
        restore = []
        fixture = nil
    }

    private func json(_ rules: String...) -> String { RuleFixtures.file(tool: "t", rules: rules) }

    private func rule(id: String = "t.r", paths: String = #"["~/.t/c"]"#, match: String) -> String {
        RuleFixtures.rule(id: id, paths: paths, match: match)
    }

    private func expand(_ jsonText: String, cap: Int = CandidateExpander.maxCandidatesPerRule,
                        deviceOf: @escaping (String) -> dev_t = CandidateExpander.defaultDeviceOf) throws -> ExpansionResult {
        let loaded = try RuleHarness.loadRules(json: jsonText, fixture: fixture)
        XCTAssertEqual(loaded.errors, [])
        let g = try ScanGuard(environment: fixture.env, protectPatterns: loaded.protectPatterns)
        return try CandidateExpander.expand(loaded.allRules[0], userID: getuid(), pathGuard: g, cap: cap, deviceOf: deviceOf)
    }

    func testSelfMissingPathYieldsNothingAndNoWarning() async throws {
        let r = try await RuleHarness.run(json: json(rule(match: #"{"kind":"self"}"#)), fixture: fixture)
        XCTAssertTrue(r.items.isEmpty)
        XCTAssertTrue(r.warnings.isEmpty)
    }

    func testSelfSymlinkIsNeverAnItem() async throws {
        try fixture.dir("real")
        try fixture.symlink(".t/c", to: fixture.abs("real"))
        let r = try await RuleHarness.run(json: json(rule(match: #"{"kind":"self"}"#)), fixture: fixture)
        XCTAssertTrue(r.items.isEmpty)
        XCTAssertTrue(r.warnings.isEmpty)
    }

    func testChildrenGlobTypeAndHidden() async throws {
        try fixture.file(".t/c/a.txt")
        try fixture.file(".t/c/.hidden")
        try fixture.file(".t/c/.cache1")
        try fixture.dir(".t/c/sub")
        let all = try await RuleHarness.run(json: json(rule(match: #"{"kind":"children"}"#)), fixture: fixture)
        XCTAssertEqual(all.paths, [fixture.abs(".t/c/a.txt"), fixture.abs(".t/c/sub")])
        let dot = try await RuleHarness.run(json: json(rule(match: #"{"kind":"children","glob":".cache*"}"#)), fixture: fixture)
        XCTAssertEqual(dot.paths, [fixture.abs(".t/c/.cache1")])
        let hidden = try await RuleHarness.run(json: json(rule(match: #"{"kind":"children","includeHidden":true,"type":"file"}"#)), fixture: fixture)
        XCTAssertEqual(hidden.paths, [fixture.abs(".t/c/.cache1"), fixture.abs(".t/c/.hidden"), fixture.abs(".t/c/a.txt")])
        let files = try await RuleHarness.run(json: json(rule(match: #"{"kind":"children","type":"file"}"#)), fixture: fixture)
        XCTAssertEqual(files.paths, [fixture.abs(".t/c/a.txt")])
    }

    func testChildrenExcludeUsesMatchesEither() async throws {
        try fixture.file(".t/c/secret\u{301}")
        try fixture.file(".t/c/ok")
        let r = try await RuleHarness.run(
            json: json(rule(match: #"{"kind":"children","exclude":["secret*"]}"#)), fixture: fixture)
        XCTAssertEqual(r.paths, [fixture.abs(".t/c/ok")])
    }

    func testChildrenDepth2RequiresRealIntermediateDirs() async throws {
        try fixture.file(".t/c/real/f.jsonl")
        try fixture.dir("elsewhere")
        try fixture.file("elsewhere/g.jsonl")
        try fixture.symlink(".t/c/link", to: fixture.abs("elsewhere"))
        let r = try await RuleHarness.run(
            json: json(rule(match: #"{"kind":"children","depth":2,"glob":"*.jsonl","type":"file"}"#)), fixture: fixture)
        XCTAssertEqual(r.paths, [fixture.abs(".t/c/real/f.jsonl")])
    }

    func testChildrenSortedDeterministically() throws {
        for n in ["b", "a", "d", "c"] { try fixture.file(".t/c/\(n)") }
        let result = try expand(json(rule(match: #"{"kind":"children"}"#)))
        XCTAssertEqual(result.candidates.map { ($0.path as NSString).lastPathComponent }, ["a", "b", "c", "d"])
    }

    private let findMatch = #"{"kind":"find","name":".cachex","marker":".git","maxDepth":5}"#

    func testFindRequiresSiblingMarkerAndPrunes() async throws {
        try fixture.dir(".t/c/repo/.git")
        try fixture.file(".t/c/repo/.cachex/inner/f")
        try fixture.dir(".t/c/repo/.cachex/nested/.git")
        try fixture.dir(".t/c/repo/.cachex/nested/.cachex")
        try fixture.file(".t/c/norepo/.cachex/f")   // no sibling .git
        let r = try await RuleHarness.run(json: json(rule(match: findMatch)), fixture: fixture)
        XCTAssertEqual(r.paths, [fixture.abs(".t/c/repo/.cachex")])
    }

    func testFindSkipsGitNodeModulesSymlinksAndOtherVolumes() throws {
        for base in ["node_modules/p", "NODE_MODULES/q", ".git/x", "vol/repo", "ok/repo"] {
            try fixture.dir(".t/c/\(base)/.git")
            try fixture.dir(".t/c/\(base)/.cachex")
        }
        try fixture.dir("elsewhere/repo/.git")
        try fixture.dir("elsewhere/repo/.cachex")
        try fixture.symlink(".t/c/link", to: fixture.abs("elsewhere"))
        let vol = fixture.abs(".t/c/vol")
        let result = try expand(json(rule(match: findMatch)),
                                deviceOf: { $0 == vol || $0.hasPrefix(vol + "/") ? 99 : 1 })
        XCTAssertEqual(result.candidates.map(\.path), [fixture.abs(".t/c/ok/repo/.cachex")])
    }

    func testFindDoesNotDescendIntoHardDeniedDir() async throws {
        try fixture.dir(".ssh/repo/.git")
        try fixture.dir(".ssh/repo/.cachex")
        try fixture.dir("ok/repo/.git")
        try fixture.dir("ok/repo/.cachex")
        let r = try await RuleHarness.run(
            json: json(rule(paths: #"["~"]"#, match: findMatch)), fixture: fixture)
        XCTAssertEqual(r.paths, [fixture.abs("ok/repo/.cachex")])
    }

    func testCandidatesDeniedByGuardAreDroppedSilently() async throws {
        try fixture.dir(".claude/projects/p/memory")
        try fixture.dir(".claude/projects/p/other")
        let r = try await RuleHarness.run(
            json: json(rule(paths: #"["~/.claude/projects"]"#, match: #"{"kind":"children","depth":2,"type":"directory"}"#)),
            fixture: fixture)
        XCTAssertEqual(r.paths, [fixture.abs(".claude/projects/p/other")])
        XCTAssertEqual(r.warnings, [])
        let direct = try expand(json(rule(paths: #"["~/.claude/projects"]"#, match: #"{"kind":"children","depth":2,"type":"directory"}"#)))
        XCTAssertEqual(direct.guardDropped, 1)
    }

    func testCandidateCapEmitsWarning() throws {
        for i in 0..<5 { try fixture.file(".t/c/f\(i)") }
        let result = try expand(json(rule(match: #"{"kind":"children"}"#)), cap: 3)
        XCTAssertEqual(result.candidates.count, 3)
        XCTAssertEqual(result.warnings.map(\.kind), [.other])
        XCTAssertTrue(result.warnings[0].message.contains("more than 3"))
    }

    func testContainerPermissionDeniedWarns() throws {
        try fixture.file(".t/c/a")
        let dir = fixture.abs(".t/c")
        restore.append(dir)
        XCTAssertEqual(chmod(dir, 0), 0)
        let result = try expand(json(rule(match: #"{"kind":"children"}"#)))
        XCTAssertTrue(result.candidates.isEmpty)
        XCTAssertEqual(result.warnings.map(\.kind), [.permissionDenied])
        XCTAssertEqual(result.warnings.first?.path, dir)
        XCTAssertEqual(result.warnings.first?.ruleID, "t.r")
    }

    func testNonDirectoryContainerWarns() throws {
        try fixture.file(".t/c")
        let result = try expand(json(rule(match: #"{"kind":"children"}"#)))
        XCTAssertEqual(result.warnings.map(\.kind), [.other])
    }

    func testDuplicateContainerExpandedOnce() throws {
        try fixture.file(".t/c/a")
        let loaded = try RuleHarness.loadRules(json: json(rule(match: #"{"kind":"children"}"#)), fixture: fixture)
        let r = loaded.allRules[0]
        let real = fixture.abs(".t/c")
        let alias = real.hasPrefix("/private/") ? String(real.dropFirst("/private".count)) : real
        let doubled = ResolvedRule(rule: r.rule, tool: r.tool, expandedPaths: [real, alias, real], unavailablePaths: [])
        let g = try ScanGuard(environment: fixture.env, protectPatterns: [])
        let result = try CandidateExpander.expand(doubled, userID: getuid(), pathGuard: g)
        XCTAssertEqual(result.candidates.count, 1)
    }

    func testOwnerMismatchDroppedSilently() throws {
        try fixture.file(".t/c/a")
        let loaded = try RuleHarness.loadRules(json: json(rule(match: #"{"kind":"children"}"#)), fixture: fixture)
        let g = try ScanGuard(environment: fixture.env, protectPatterns: [])
        let result = try CandidateExpander.expand(loaded.allRules[0], userID: getuid() + 1, pathGuard: g)
        XCTAssertTrue(result.candidates.isEmpty)
        XCTAssertEqual(result.ownerDropped, 1)
        XCTAssertTrue(result.warnings.isEmpty)
    }
}
