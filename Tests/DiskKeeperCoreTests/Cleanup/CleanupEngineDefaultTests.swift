import XCTest
@testable import DiskKeeperCore

final class CleanupEngineDefaultTests: XCTestCase {
    private func item(_ url: URL) throws -> ScanItem {
        let r = try FileSizer().sizeBlocking(of: url)
        return ScanItem(url: url, displayName: url.lastPathComponent, tool: .claudeCode, category: .systemJunk,
                        sizeAllocated: r.allocatedBytes, sizeLogical: r.logicalBytes, fileCount: r.fileCount,
                        lastModified: r.newestModification, tier: .safe, explanation: "x", ruleID: "test.rule")
    }

    func testDefaultEngineBlocksFreshFilesAndHeldFiles() async throws {
        let tmp = try TemporaryDirectory()
        let home = try tmp.dir("home")
        let cache = try tmp.file("home/Library/Caches/Foo/blob", bytes: 10)
        let env = PathEnvironment(home: home.path, temporaryDirectory: tmp.path("tmp"))
        let fresh = try CleanupEngine.makeDefault(environment: env, runningApps: FakeRunningApps(), inUse: FakeUsageSource([]))
        let dir = cache.deletingLastPathComponent()
        let plan = await fresh.plan([try item(dir)])
        XCTAssertTrue(plan.entries[0].blockers.contains(.modifiedRecently), "\(plan.entries[0].blockers)")

        let old = Date(timeIntervalSince1970: 1_577_836_800)
        for p in [cache.path, dir.path] { try setMTime(p, old) }
        let held = ProcessHold(pid: 9, name: "node", uid: getuid(), cwd: dir.path)
        let blocked = try CleanupEngine.makeDefault(environment: env, runningApps: FakeRunningApps(), inUse: FakeUsageSource([held]))
        let plan2 = await blocked.plan([try item(dir)])
        XCTAssertEqual(plan2.entries[0].blockers, [.inUse(process: "node", pid: 9)])
    }

    func testDefaultEngineBlocksSSHAndAllowsCache() async throws {
        let tmp = try TemporaryDirectory()
        let home = try tmp.dir("home")
        let ssh = try tmp.file("home/.ssh/id_test", bytes: 10)
        let cache = try tmp.file("home/Library/Caches/Foo/blob", bytes: 10)
        let env = PathEnvironment(home: home.path, temporaryDirectory: tmp.path("tmp"))
        // In-use detection is always on in the default engine; a fake source keeps this test off the real process table.
        let old = Date(timeIntervalSince1970: 1_577_836_800)
        for p in [cache.path, cache.deletingLastPathComponent().path] { try setMTime(p, old) }
        let engine = try CleanupEngine.makeDefault(environment: env, runningApps: FakeRunningApps(), inUse: FakeUsageSource([]))

        let plan = await engine.plan([try item(ssh.deletingLastPathComponent()), try item(cache.deletingLastPathComponent())])
        XCTAssertEqual(plan.entries.count, 2)
        XCTAssertTrue(plan.entries[0].blockers.contains { $0.code == "protectedPath" })
        XCTAssertTrue(plan.entries[1].isExecutable, "\(plan.entries[1].blockers)")
    }
}
