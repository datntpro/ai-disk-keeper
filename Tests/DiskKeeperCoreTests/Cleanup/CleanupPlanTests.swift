import Foundation
import XCTest
@testable import DiskKeeperCore

final class CleanupPlanTests: CleanupTestCase {
    func testDryRunChangesNothing() async throws {
        try fx.file("home/cache/a/f", bytes: 5000); try fx.file("home/cache/b", bytes: 100)
        let items = [try item("home/cache/a"), try item("home/cache/b")]
        let before = try snapshot()
        let engine = try makeEngine()
        let plan = await engine.plan(items)
        XCTAssertEqual(try snapshot(), before)
        XCTAssertTrue(trashContents().isEmpty)
        XCTAssertFalse(exists("audit/audit.jsonl"))
        XCTAssertEqual(plan.executableEntries.count, 2)
    }

    func testKeepTierBlocked() async throws {
        try fx.file("home/cache/a", bytes: 10)
        let plan = await (try makeEngine()).plan([try item("home/cache/a", tier: .keep)])
        XCTAssertEqual(plan.entries[0].blockers, [.keepTier])
    }

    func testNoneMethodBlocked() async throws {
        try fx.file("home/cache/a", bytes: 10)
        let plan = await (try makeEngine()).plan([try item("home/cache/a", method: .none)])
        XCTAssertEqual(plan.entries[0].blockers, [.notActionable])
    }

    func testWorktreeAndToolCommandNotSupportedYet() async throws {
        try fx.file("home/cache/a", bytes: 10); try fx.file("home/cache/b", bytes: 10)
        let plan = await (try makeEngine()).plan([
            try item("home/cache/a", method: .trashWorktree(mainRepoPath: "/x")),
            try item("home/cache/b", method: .toolCommand(command: "c", arguments: []))])
        XCTAssertEqual(plan.entries[0].blockers, [.methodNotSupported("trashWorktree")])
        XCTAssertEqual(plan.entries[1].blockers, [.methodNotSupported("toolCommand")])
    }

    func testProtectedPathBlockedEvenIfPassedIn() async throws {
        try fx.file("home/.ssh/id_x", bytes: 10)
        let plan = await (try makeEngine()).plan([try item("home/.ssh/id_x", tier: .safe)])
        XCTAssertTrue(plan.entries[0].blockers.contains { if case .protectedPath(.protectedPath, _, _, _) = $0 { true } else { false } })
        XCTAssertFalse(plan.entries[0].isExecutable)
    }

    func testMissingItemBlocked() async throws {
        try fx.file("home/cache/a", bytes: 10)
        let it = try item("home/cache/a")
        try FileManager.default.removeItem(atPath: it.path)
        let plan = await (try makeEngine()).plan([it])
        XCTAssertTrue(plan.entries[0].blockers.contains(.missing))
    }

    func testSymlinkItemBlocked() async throws {
        try fx.file("home/cache/real", bytes: 10)
        try fx.symlink("home/cache/link", to: fx.path("home/cache/real"))
        let url = URL(fileURLWithPath: fx.path("home/cache/link"))
        let it = ScanItem(url: url, displayName: "l", tool: .claudeCode, category: .buildArtifact, sizeAllocated: 0,
                          sizeLogical: 0, fileCount: 0, lastModified: Date(), tier: .safe, explanation: "", ruleID: "r")
        let plan = await (try makeEngine()).plan([it])
        XCTAssertTrue(plan.entries[0].blockers.contains(.isSymlink))
    }

    func testDuplicateAndNestedBlocked() async throws {
        try fx.file("home/cache/a/b", bytes: 10)
        let a = try item("home/cache/a"), b = try item("home/cache/a/b")
        let plan = await (try makeEngine()).plan([a, a, b])
        XCTAssertTrue(plan.entries[0].isExecutable)
        XCTAssertEqual(plan.entries[1].blockers, [.duplicate])
        XCTAssertEqual(plan.entries[2].blockers, [.nestedInAnotherItem(otherItemID: a.id)])
    }

    func testAppRunningAndUnknownBlocked() async throws {
        try fx.file("home/cache/a", bytes: 10)
        let it = try item("home/cache/a", quit: "com.x.app")
        var plan = await (try makeEngine(apps: FakeRunningApps(["com.x.app": true]))).plan([it])
        XCTAssertEqual(plan.entries[0].blockers, [.appRunning(bundleID: "com.x.app")])
        plan = await (try makeEngine(apps: UnknownRunningApps())).plan([it])
        XCTAssertEqual(plan.entries[0].blockers, [.appStateUnknown(bundleID: "com.x.app")])
        plan = await (try makeEngine(apps: FakeRunningApps())).plan([it])
        XCTAssertTrue(plan.entries[0].isExecutable)
    }

    func testPermanentDeleteDisabledByDefault() async throws {
        try fx.file("home/cache/a", bytes: 10)
        var o = CleanupOptions(); o.requestPermanentDelete = true
        let plan = await (try makeEngine(options: o)).plan([try item("home/cache/a")])
        XCTAssertEqual(plan.entries[0].action, .deletePermanently)
        XCTAssertEqual(plan.entries[0].blockers, [.permanentDeleteDisabled])
    }

    func testReclaimableBytesSumsExecutableOnly() async throws {
        try fx.file("home/cache/a", bytes: 8192); try fx.file("home/cache/b", bytes: 8192)
        let a = try item("home/cache/a"), b = try item("home/cache/b", tier: .keep)
        let plan = await (try makeEngine()).plan([a, b])
        XCTAssertEqual(plan.reclaimableBytes, a.sizeAllocated)
        XCTAssertEqual(plan.blockedCount, 1)
    }

    func testPlanIsCodableRoundTrip() async throws {
        try fx.file("home/cache/a", bytes: 10); try fx.file("home/.ssh/k", bytes: 1)
        let plan = await (try makeEngine()).plan([try item("home/cache/a"), try item("home/.ssh/k")])
        let data = try DiskKeeperJSON.makeEncoder().encode(plan)
        let back = try DiskKeeperJSON.makeDecoder().decode(CleanupPlan.self, from: data)
        XCTAssertEqual(back.id, plan.id)
        XCTAssertEqual(back.entries.map(\.blockers), plan.entries.map(\.blockers))
        XCTAssertEqual(back.entries.map(\.fingerprint), plan.entries.map(\.fingerprint))
        // Dates round-trip at millisecond precision.
        XCTAssertEqual(back.createdAt.timeIntervalSince(plan.createdAt), 0, accuracy: 0.001)
        XCTAssertEqual(back.entries.map(\.item.id), plan.entries.map(\.item.id))
        XCTAssertEqual(back.entries.map(\.action), plan.entries.map(\.action))
    }
}
