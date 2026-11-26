import XCTest
@testable import DiskKeeperCore

/// #41: shell rc/history files and `~/.claude/settings*.json.*` backups are protected.
final class ProtectedShellConfigTests: XCTestCase {
    private let home = "/Users/tester"
    private let tmp = "/var/folders/zz/T/"

    private let protectedRel = [
        ".zshrc", ".zshenv", ".zprofile", ".zlogin", ".zlogout", ".zsh_history", ".zsh_sessions",
        ".bashrc", ".bash_profile", ".bash_login", ".bash_logout", ".bash_history", ".bash_sessions",
        ".profile", ".inputrc", ".config/fish", ".local/share/fish/fish_history", ".python_history",
        ".node_repl_history", ".lesshst", ".viminfo",
        ".claude/settings.json.bak", ".claude/settings.local.json.backup", ".claude/settings.json.orig",
    ]

    private func policy() throws -> ProtectedPaths {
        try ProtectedPaths(homeDirectory: home, temporaryDirectory: tmp, resolver: FakePathResolver())
    }

    func testGuardDeniesEachEntryAndItsChildren() throws {
        let p = try policy()
        for rel in protectedRel {
            XCTAssertEqual(p.check("\(home)/\(rel)").denial?.reason, .protectedPath, rel)
            XCTAssertEqual(p.check("\(home)/\(rel)/child").denial?.reason, .protectedPath, rel)
        }
    }

    func testNoOverMatch() throws {
        let p = try policy()
        for rel in [".zsh_cache/x", ".zsh_cache", ".config/other/x", ".cache/foo",
                    ".local/share/other", ".claude/settingsfoo", ".claude/projects/a/x.json.bak",
                    ".bashrc2", ".local/share/fish/other"] {
            let r = p.check("\(home)/\(rel)").denial?.reason
            XCTAssertNotEqual(r, .protectedPath, rel)
        }
        XCTAssertNil(p.check("\(home)/.zsh_cache/x").denial)
        XCTAssertNil(p.check("\(home)/.config/other/x").denial)
    }

    func testChildrenRuleWithDotGlobNeverYieldsShellFiles() async throws {
        let fixture = try FixtureHome()
        for rel in protectedRel.filter({ !$0.hasPrefix(".claude") && !$0.contains("/") }) {
            _ = try fixture.file(rel)
        }
        _ = try fixture.file(".config/fish/config.fish")
        _ = try fixture.file(".local/share/fish/fish_history")
        _ = try fixture.file(".zsh_cache/x")
        _ = try fixture.file(".claude/settings.json.bak")
        let match = #"{"kind":"children","glob":".*","includeHidden":true}"#
        let json = RuleFixtures.file(tool: "t", rules: [RuleFixtures.rule(id: "t.home", paths: #"["~"]"#, match: match)])
        let r = try await RuleHarness.run(json: json, fixture: fixture)
        for rel in protectedRel {
            XCTAssertNil(r.item(fixture.abs(rel)), rel)
        }
    }
}
