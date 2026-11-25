import XCTest
@testable import DiskKeeperCore

final class CopilotRulesTests: XCTestCase {
    private let f = "copilot.json"
    private let code = "Library/Application Support/Code"
    private let insiders = "Library/Application Support/Code - Insiders"

    private func populate(_ fx: FixtureHome) throws {
        try OtherToolRules.agedDir(fx, "\(code)/User/workspaceStorage/abc/GitHub.copilot-chat", days: 20)
        try OtherToolRules.agedDir(fx, "\(code)/User/workspaceStorage/new/GitHub.copilot-chat", days: 3)
        try fx.file("\(code)/User/workspaceStorage/abc/other.ext/x")
        try OtherToolRules.agedDir(fx, "\(insiders)/User/workspaceStorage/zzz/GitHub.copilot-chat", days: 20)
    }

    func testCopilotAbsentProducesNothing() async throws { try await OtherToolRules.assertAbsent(f) }

    func testCopilotFileLoadsWithRealGuard() throws { try OtherToolRules.assertLoads(f, tool: "copilot") }

    func testCopilotChatDirPerWorkspace() async throws {
        let fx = try FixtureHome()
        try populate(fx)
        let r = try await OtherToolRules.run(f, fx)
        XCTAssertEqual(r.errors, [])
        XCTAssertEqual(r.pairs, [
            "\(code)/User/workspaceStorage/abc/GitHub.copilot-chat:review",
            "\(code)/User/workspaceStorage/new/GitHub.copilot-chat:keep",
            "\(insiders)/User/workspaceStorage/zzz/GitHub.copilot-chat:review",
        ].sorted())
        XCTAssertNil(r.item("\(code)/User/workspaceStorage/abc/other.ext"))
        XCTAssertNil(r.item("\(code)/User/workspaceStorage/abc"))
    }

    func testCopilotQuitsTheRightEditor() async throws {
        let fx = try FixtureHome()
        try populate(fx)
        let r = try await OtherToolRules.run(f, fx)
        XCTAssertEqual(r.item("\(code)/User/workspaceStorage/abc/GitHub.copilot-chat")?.requiresAppQuit, "com.microsoft.VSCode")
        XCTAssertEqual(r.item("\(insiders)/User/workspaceStorage/zzz/GitHub.copilot-chat")?.requiresAppQuit,
                       "com.microsoft.VSCodeInsiders")
    }

    func testCopilotProtectedFilesNeverItems() async throws {
        try await OtherToolRules.assertProtected(f, files: [
            "\(code)/User/globalStorage/state.vscdb", "\(code)/User/globalStorage/state.vscdb.backup", "\(code)/User/settings.json",
            "\(insiders)/User/globalStorage/state.vscdb", "\(insiders)/User/settings.json",
            "\(code)/User/workspaceStorage/abc/chatSessions/s.json", "\(code)/User/workspaceStorage/abc/chatEditingSessions/e/x",
            "\(insiders)/User/workspaceStorage/zzz/chatSessions/s.json",
            ".config/github-copilot/hosts.json", ".config/github-copilot/apps.json",
        ])
    }

    func testCopilotReadOnly() async throws { try await OtherToolRules.assertReadOnly(f, populate: populate) }
}
