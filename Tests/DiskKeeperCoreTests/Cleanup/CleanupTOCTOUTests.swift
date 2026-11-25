import Foundation
import XCTest
@testable import DiskKeeperCore

final class CleanupTOCTOUTests: CleanupTestCase {
    func testSwapToSymlinkAfterPlanIsRefused() async throws {
        try fx.file("home/cache/x/f", bytes: 10); try fx.file("home/.ssh/k", bytes: 10)
        let engine = try makeEngine()
        let plan = await engine.plan([try item("home/cache/x")])
        XCTAssertTrue(plan.entries[0].isExecutable)
        try FileManager.default.removeItem(atPath: fx.path("home/cache/x"))
        try fx.symlink("home/cache/x", to: fx.path("home/.ssh"))
        let report = try await engine.execute(plan)
        XCTAssertTrue(skippedCodes(report.results[0].outcome).contains("isSymlink"))
        XCTAssertTrue(exists("home/.ssh/k")); XCTAssertTrue(trashContents().isEmpty)
    }

    func testParentSwappedToSymlinkIsRefused() async throws {
        try fx.file("home/cache/x/f", bytes: 10); try fx.file("home/other/x/f", bytes: 10)
        let engine = try makeEngine()
        let plan = await engine.plan([try item("home/cache/x")])
        try FileManager.default.moveItem(atPath: fx.path("home/cache"), toPath: fx.path("home/cache-away"))
        try fx.symlink("home/cache", to: fx.path("home/other"))
        let report = try await engine.execute(plan)
        XCTAssertTrue(skippedCodes(report.results[0].outcome).contains("symlinkInParentChain"))
        XCTAssertTrue(exists("home/other/x/f")); XCTAssertTrue(trashContents().isEmpty)
    }

    func testReplacedWithDifferentInodeIsRefused() async throws {
        try fx.file("home/cache/x/f", bytes: 100)
        let it = try item("home/cache/x")
        let engine = try makeEngine()
        let plan = await engine.plan([it])
        try FileManager.default.removeItem(atPath: fx.path("home/cache/x"))
        try fx.file("home/cache/x/f", bytes: 100)
        try fx.setMTime("home/cache/x/f", it.lastModified!)
        let report = try await engine.execute(plan)
        XCTAssertTrue(skippedCodes(report.results[0].outcome).contains("identityChanged"))
        XCTAssertTrue(exists("home/cache/x/f"))
    }

    func testTmpdirAliasIsNotAFalseParentSymlink() async throws {
        try fx.file("tmp/build/x", bytes: 10)
        let real = fx.path("tmp/build/x")
        let aliased = real.hasPrefix("/private/") ? String(real.dropFirst("/private".count)) : real
        let url = URL(fileURLWithPath: aliased)
        let r = try FileSizer().sizeBlocking(of: url)
        let it = ScanItem(url: url, displayName: "x", tool: .claudeCode, category: .buildArtifact,
                          sizeAllocated: r.allocatedBytes, sizeLogical: r.logicalBytes, fileCount: r.fileCount,
                          lastModified: r.newestModification, tier: .safe, explanation: "", ruleID: "r")
        let engine = try makeEngine()
        let plan = await engine.plan([it])
        XCTAssertEqual(plan.entries[0].blockers, [])
        let report = try await engine.execute(plan)
        guard case .trashed = report.results[0].outcome else { return XCTFail("\(report.results[0].outcome)") }
    }

    func testPostTrashFingerprintMismatchReportedFailed() async throws {
        try fx.file("home/cache/x", bytes: 10); try fx.file("home/cache/decoy", bytes: 10)
        let lying = LyingTrash(inner: DirectoryTrash(root: trashDir), reported: URL(fileURLWithPath: fx.path("home/cache/decoy")))
        let engine = try makeEngine(trash: lying)
        let plan = await engine.plan([try item("home/cache/x")])
        let report = try await engine.execute(plan)
        guard case .failed(let m) = report.results[0].outcome else { return XCTFail() }
        XCTAssertTrue(m.contains("does not match"))
        XCTAssertEqual(try AuditLog.read(auditURL)[0].result, "failed")
    }
}
