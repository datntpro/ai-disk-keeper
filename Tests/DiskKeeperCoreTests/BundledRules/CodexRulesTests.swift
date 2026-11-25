import XCTest
@testable import DiskKeeperCore

final class CodexRulesTests: XCTestCase {
    private let f = "codex.json"

    private func populate(_ fx: FixtureHome, root x: String = ".codex") throws {
        try OtherToolRules.agedDir(fx, "\(x)/sessions/2026/01/01", days: 40)
        try OtherToolRules.agedDir(fx, "\(x)/sessions/2026/02/02", days: 15)
        try OtherToolRules.agedDir(fx, "\(x)/sessions/2026/03/03", days: 2)
        try OtherToolRules.agedDir(fx, "\(x)/archived_sessions/a", days: 40)
        try OtherToolRules.agedDir(fx, "\(x)/archived_sessions/b", days: 10)
        try OtherToolRules.agedDir(fx, "\(x)/log/old", days: 4)
        try fx.file("\(x)/log/fresh.log", modified: OtherToolRules.days(0.1))
    }

    func testCodexAbsentProducesNothing() async throws { try await OtherToolRules.assertAbsent(f) }

    func testCodexFileLoadsWithRealGuard() throws { try OtherToolRules.assertLoads(f, tool: "codex") }

    func testCodexRulesFindFixtureItems() async throws {
        let fx = try FixtureHome()
        try populate(fx)
        let r = try await OtherToolRules.run(f, fx)
        XCTAssertEqual(r.errors, [])
        XCTAssertEqual(r.pairs, [
            ".codex/sessions/2026/01/01:safe", ".codex/sessions/2026/02/02:review", ".codex/sessions/2026/03/03:keep",
            ".codex/archived_sessions/a:safe", ".codex/archived_sessions/b:review",
            ".codex/log/old:safe", ".codex/log/fresh.log:keep",
        ].sorted())
    }

    func testCodexDayFoldersAndCodexHome() async throws {
        let fx = try FixtureHome()
        try populate(fx, root: "elsewhere/codex-home")
        try fx.file(".codex/auth.json")
        try fx.file("elsewhere/codex-home/auth.json")
        let r = try await OtherToolRules.run(f, fx, variables: ["CODEX_HOME": fx.abs("elsewhere/codex-home")])
        XCTAssertEqual(r.tier("elsewhere/codex-home/sessions/2026/01/01"), .safe)
        XCTAssertEqual(r.tier("elsewhere/codex-home/sessions/2026/02/02"), .review)
        XCTAssertEqual(r.tier("elsewhere/codex-home/sessions/2026/03/03"), .keep)
        XCTAssertTrue(r.items.allSatisfy { $0.path.hasPrefix(fx.abs("elsewhere/codex-home")) })
        XCTAssertFalse(r.pathGuard.check(fx.abs("elsewhere/codex-home/auth.json")).isAllowed)
    }

    func testCodexProtectedFilesNeverItems() async throws {
        try await OtherToolRules.assertProtected(f, files: [
            ".codex/auth.json", ".codex/config.toml", ".codex/AGENTS.md", ".codex/history.jsonl",
            ".codex/prompts/p.md", ".codex/skills/s/SKILL.md",
        ])
    }

    func testCodexReadOnly() async throws { try await OtherToolRules.assertReadOnly(f) { try self.populate($0) } }
}
