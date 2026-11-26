import XCTest
@testable import DiskKeeperCore

final class CleanupEngineDefaultTests: XCTestCase {
    private func item(_ url: URL) throws -> ScanItem {
        let r = try FileSizer().sizeBlocking(of: url)
        return ScanItem(url: url, displayName: url.lastPathComponent, tool: .claudeCode, category: .systemJunk,
                        sizeAllocated: r.allocatedBytes, sizeLogical: r.logicalBytes, fileCount: r.fileCount,
                        lastModified: r.newestModification, tier: .safe, explanation: "x", ruleID: "test.rule")
    }

    func testDefaultEngineBlocksSSHAndAllowsCache() async throws {
        let tmp = try TemporaryDirectory()
        let home = try tmp.dir("home")
        let ssh = try tmp.file("home/.ssh/id_test", bytes: 10)
        let cache = try tmp.file("home/Library/Caches/Foo/blob", bytes: 10)
        let env = PathEnvironment(home: home.path, temporaryDirectory: tmp.path("tmp"))
        let engine = try CleanupEngine.makeDefault(environment: env, runningApps: FakeRunningApps())

        let plan = await engine.plan([try item(ssh.deletingLastPathComponent()), try item(cache.deletingLastPathComponent())])
        XCTAssertEqual(plan.entries.count, 2)
        XCTAssertTrue(plan.entries[0].blockers.contains { $0.code == "protectedPath" })
        XCTAssertTrue(plan.entries[1].isExecutable, "\(plan.entries[1].blockers)")
    }
}
