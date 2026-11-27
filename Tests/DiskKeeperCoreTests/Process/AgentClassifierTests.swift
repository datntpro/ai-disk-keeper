import XCTest
@testable import DiskKeeperCore

final class AgentClassifierTests: XCTestCase {
    private func rec(_ pid: pid_t, _ ppid: pid_t, _ name: String, path: String? = nil) -> ProcessRecord {
        ProcessRecord(pid: pid, ppid: ppid, name: name, executablePath: path)
    }

    func testTable() {
        let cases: [(String, AgentKind)] = [
            ("claude", .claude), ("codex", .codex), ("gemini", .gemini), ("aider", .aider), ("cursor-agent", .cursor),
            ("node", .node), ("bun", .bun), ("python3.12", .python), ("Python", .python), ("go", .go),
            ("swift-frontend", .swift), ("swiftc", .swift), ("cargo", .cargo), ("rustc", .cargo), ("git", .git),
            ("xcodebuild", .xcodebuild), ("docker", .docker), ("com.docker.backend", .docker),
            ("tart", .vm), ("com.apple.Virtualization.VirtualMachine", .vm),
            ("mdworker_shared", .spotlight), ("mds", .spotlight), ("mds_stores", .spotlight),
            ("wdavdaemon", .defender), ("epsext", .defender), ("Safari", .other), ("zsh", .other),
        ]
        for (name, kind) in cases { XCTAssertEqual(AgentClassifier.kind(name: name, path: nil), kind, name) }
    }

    func testClaudeDesktopAppIsNotTheCLI() {
        XCTAssertEqual(AgentClassifier.kind(name: "Claude", path: "/Applications/Claude.app/Contents/MacOS/Claude"), .other)
        XCTAssertEqual(AgentClassifier.kind(name: "Orca", path: "/Applications/Orca.app/Contents/MacOS/Orca"), .orca)
    }

    func testNativeClaudeCodeInstallIsRecognisedByPath() {
        let home = "/Users/x/.local/share/claude/versions/2.1.330"
        XCTAssertEqual(AgentClassifier.kind(name: "2.1.330", path: home), .claude)
        let r = rec(7, 1, "2.1.330", path: home)
        XCTAssertEqual(AgentClassifier.classify(r), .claude)
        let node = rec(8, 7, "node", path: "/opt/homebrew/bin/node")
        XCTAssertEqual(AgentClassifier.agent(of: node, ancestors: [r]), .claude)
    }

    func testNpmClaudeCodeIsNodeWithClaudeTitle() {
        // The npm install runs `node cli.js` and sets its process title to "claude".
        XCTAssertEqual(AgentClassifier.kind(name: "claude", path: "/opt/homebrew/bin/node"), .claude)
        XCTAssertEqual(AgentClassifier.kind(name: "node", path: "/opt/homebrew/bin/node"), .node)
    }

    func testCodexNativeAndNpm() {
        XCTAssertEqual(AgentClassifier.kind(name: "codex", path: "/opt/homebrew/bin/codex"), .codex)
        XCTAssertEqual(AgentClassifier.kind(name: "codex-aarch64-apple-darwin",
                                            path: "/usr/local/lib/node_modules/@openai/codex/vendor/codex"), .codex)
        XCTAssertEqual(AgentClassifier.kind(name: "weird", path: "/usr/local/lib/node_modules/@openai/codex/bin/codex"), .codex)
    }

    func testGuiAppsNamedLikeAgentsAreNotAgentCLIs() {
        XCTAssertEqual(AgentClassifier.kind(name: "Gemini", path: "/Applications/Gemini.app/Contents/MacOS/Gemini"), .other)
        XCTAssertEqual(AgentClassifier.kind(name: "Codex", path: "/Applications/Codex.app/Contents/MacOS/Codex"), .other)
    }

    func testNodeUnderClaudeIsAttributedToClaude() {
        let claude = rec(1, 0, "claude"), shell = rec(2, 1, "zsh"), node = rec(3, 2, "node")
        XCTAssertEqual(AgentClassifier.agent(of: node, ancestors: [shell, claude]), .claude)
        XCTAssertEqual(AgentClassifier.classify(node), .node, "the tool stays node")
        XCTAssertEqual(AgentClassifier.agent(of: claude, ancestors: []), .claude)
        XCTAssertNil(AgentClassifier.agent(of: node, ancestors: [shell]))
    }

    func testNearestAgentWins() {
        let outer = rec(1, 0, "codex"), inner = rec(2, 1, "claude"), tool = rec(3, 2, "git")
        XCTAssertEqual(AgentClassifier.agent(of: tool, ancestors: [inner, outer]), .claude)
    }
}
