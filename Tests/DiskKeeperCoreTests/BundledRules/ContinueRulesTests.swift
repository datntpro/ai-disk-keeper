import XCTest
@testable import DiskKeeperCore

final class ContinueRulesTests: XCTestCase {
    private let f = "continue.json"

    private func populate(_ fx: FixtureHome) throws {
        try fx.file(".continue/sessions/old.json", bytes: 10, modified: OtherToolRules.days(40))
        try fx.file(".continue/sessions/mid.json", bytes: 10, modified: OtherToolRules.days(15))
        try fx.file(".continue/sessions/new.json", bytes: 10, modified: OtherToolRules.days(2))
        try fx.file(".continue/sessions/sessions.json", bytes: 10, modified: OtherToolRules.days(40))
        try fx.file(".continue/index/lance/x", bytes: 10)
        try fx.file(".continue/logs/core.log", bytes: 10, modified: OtherToolRules.days(5))
        try fx.file(".continue/dev_data/chat.jsonl", bytes: 10)
    }

    func testContinueAbsentProducesNothing() async throws { try await OtherToolRules.assertAbsent(f) }

    func testContinueFileLoadsWithRealGuard() throws { try OtherToolRules.assertLoads(f, tool: "continue") }

    func testContinueSessionsIndexExcluded() async throws {
        let fx = try FixtureHome()
        try populate(fx)
        let r = try await OtherToolRules.run(f, fx)
        XCTAssertEqual(r.errors, [])
        XCTAssertNil(r.item(".continue/sessions/sessions.json"))
        XCTAssertEqual(r.pairs, [
            ".continue/sessions/old.json:safe", ".continue/sessions/mid.json:review", ".continue/sessions/new.json:keep",
            ".continue/index:review", ".continue/logs/core.log:safe", ".continue/dev_data:review",
        ].sorted())
    }

    func testContinueProtectedFilesNeverItems() async throws {
        try await OtherToolRules.assertProtected(f, files: [
            ".continue/config.yaml", ".continue/config.json", ".continue/assistants/a.yaml", ".continue/prompts/p.prompt",
            ".continue/rules/r.md", ".continue/mcpServers/m.yaml",
        ])
    }

    func testContinueReadOnly() async throws { try await OtherToolRules.assertReadOnly(f, populate: populate) }
}
