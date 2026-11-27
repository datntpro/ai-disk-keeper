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
