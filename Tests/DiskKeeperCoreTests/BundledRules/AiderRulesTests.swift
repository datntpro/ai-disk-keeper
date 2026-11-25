import XCTest
@testable import DiskKeeperCore

final class AiderRulesTests: XCTestCase {
    private let f = "aider.json"

    private func populate(_ fx: FixtureHome) throws {
        try fx.dir("code/r/.git")
        try fx.file("code/r/.aider.tags.cache.v4/cache.db", bytes: 10)
        try fx.file("code/r/.aider.chat.history.md", bytes: 10, modified: OtherToolRules.days(20))
        try fx.file("code/r/.aider.input.history", bytes: 10)
    }

    func testAiderAbsentProducesNothing() async throws { try await OtherToolRules.assertAbsent(f) }

    func testAiderFileLoadsWithRealGuard() throws { try OtherToolRules.assertLoads(f, tool: "aider") }

    func testAiderFindRequiresGitMarker() async throws {
        let fx = try FixtureHome()
        try populate(fx)
        // No .git marker.
        try fx.file("code/nogit/.aider.tags.cache.v4/cache.db")
        // Inside node_modules: never searched.
        try fx.dir("code/n/.git")
        try fx.file("code/n/node_modules/pkg/.aider.tags.cache.v4/cache.db")
        try fx.dir("code/n/node_modules/pkg/.git")
        let r = try await OtherToolRules.run(f, fx)
        XCTAssertEqual(r.errors, [])
        XCTAssertEqual(r.pairs, [
            "code/r/.aider.tags.cache.v4:safe", "code/r/.aider.chat.history.md:review", "code/r/.aider.input.history:review",
        ].sorted())
        XCTAssertEqual(r.item("code/r/.aider.tags.cache.v4")?.project?.id, fx.abs("code/r"))
    }

    func testAiderFreshChatHistoryIsKept() async throws {
        let fx = try FixtureHome()
        try fx.dir("src/a/.git")
        try fx.file("src/a/.aider.chat.history.md", bytes: 10, modified: OtherToolRules.days(2))
        let r = try await OtherToolRules.run(f, fx)
        XCTAssertEqual(r.tier("src/a/.aider.chat.history.md"), .keep)
    }

    func testAiderDoesNotSearchHomeOrOrca() async throws {
        let fx = try FixtureHome()
        try fx.dir(".git")
        try fx.file(".aider.chat.history.md")
        try fx.dir("orca/workspaces/w/.git")
        try fx.file("orca/workspaces/w/.aider.chat.history.md")
        let r = try await OtherToolRules.run(f, fx)
        XCTAssertTrue(r.items.isEmpty, "\(r.pairs)")
    }

    func testAiderProtectedFilesNeverItems() async throws {
        try await OtherToolRules.assertProtected(f, files: [
            ".aider.conf.yml", ".aider.model.settings.yml", ".aider.model.metadata.json",
        ])
    }

    func testAiderReadOnly() async throws { try await OtherToolRules.assertReadOnly(f, populate: populate) }
}
