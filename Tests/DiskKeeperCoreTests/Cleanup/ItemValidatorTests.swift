import Darwin
import Foundation
import XCTest
@testable import DiskKeeperCore

final class ItemValidatorTests: CleanupTestCase {
    private func validator(tol: ChangeTolerance = .default, uid: uid_t = getuid(),
                           apps: any RunningAppChecking = FakeRunningApps()) throws -> ItemValidator {
        ItemValidator(pathGuard: try makeGuard(), userID: uid, runningApps: apps, tolerance: tol)
    }

    func testEveryBlockerHasCodeAndMessage() {
        let d = ChangeDetail(scannedBytes: 1, currentBytes: 2, scannedModified: nil, currentModified: nil)
        let all: [(CleanupBlocker, String)] = [
            (.keepTier, "keepTier"), (.notActionable, "notActionable"),
            (.methodNotSupported("x"), "methodNotSupported"),
            (.protectedPath(.protectedPath, message: "m"), "protectedPath"), (.missing, "missing"),
            (.isSymlink, "isSymlink"), (.notOwnedByUser(uid: 1), "notOwnedByUser"),
            (.symlinkInParentChain(resolvedParent: "/p"), "symlinkInParentChain"),
            (.identityChanged, "identityChanged"), (.changedSinceScan(d), "changedSinceScan"),
            (.appRunning(bundleID: "b"), "appRunning"), (.appStateUnknown(bundleID: "b"), "appStateUnknown"),
            (.nestedInAnotherItem(otherItemID: "o"), "nestedInAnotherItem"), (.duplicate, "duplicate"),
            (.permanentDeleteDisabled, "permanentDeleteDisabled"), (.sizingFailed("e"), "sizingFailed"),
        ]
        for (b, code) in all {
            XCTAssertEqual(b.code, code); XCTAssertFalse(b.message.isEmpty)
            let data = try? JSONEncoder().encode(b)
            XCTAssertEqual(data.flatMap { try? JSONDecoder().decode(CleanupBlocker.self, from: $0) }, b)
        }
    }

    func testNotOwnedByUser() throws {
        try fx.file("home/cache/a", bytes: 10)
        let r = try validator(uid: getuid() &+ 1).fastChecks(try item("home/cache/a"), expected: nil)
        XCTAssertEqual(r.blockers, [.notOwnedByUser(uid: UInt32(getuid()))])
    }

    func testMtimeToleranceEdges() async throws {
        try fx.file("home/cache/a", bytes: 10)
        var it = try item("home/cache/a")
        let actual = it.lastModified!
        let v = try validator(tol: ChangeTolerance(mtimeSlack: 2))
        it.lastModified = actual.addingTimeInterval(-2)       // exactly at slack
        let atSlack = await v.changeCheck(it)
        XCTAssertEqual(atSlack, [])
        it.lastModified = actual.addingTimeInterval(-2.5)     // over
        let over = await v.changeCheck(it)
        XCTAssertEqual(over.map(\.code), ["changedSinceScan"])
        it.lastModified = nil
        let unknown = await v.changeCheck(it)
        XCTAssertEqual(unknown.map(\.code), ["changedSinceScan"])
    }

    func testSizeToleranceEdges() async throws {
        try fx.file("home/cache/a", bytes: 8192)
        var it = try item("home/cache/a")
        let actual = it.sizeAllocated
        let v = try validator(tol: ChangeTolerance(mtimeSlack: 2, sizeSlackBytes: 1000, sizeSlackFraction: 0))
        it.sizeAllocated = actual - 1000
        let atSlack = await v.changeCheck(it)
        XCTAssertEqual(atSlack, [])
        it.sizeAllocated = actual - 1001
        let over = await v.changeCheck(it)
        XCTAssertEqual(over.map(\.code), ["changedSinceScan"])
    }

    func testChangeCheckMissingAndPolicy() async throws {
        let ghost = ScanItem(url: URL(fileURLWithPath: fx.path("home/cache/ghost")), displayName: "g", tool: .claudeCode,
                             category: .buildArtifact, sizeAllocated: 0, sizeLogical: 0, fileCount: 0,
                             lastModified: Date(), tier: .safe, explanation: "", ruleID: "r")
        let missing = await (try validator()).changeCheck(ghost)
        XCTAssertEqual(missing, [.missing])
        var o = CleanupOptions(); o.permanentDeleteEnabled = true
        XCTAssertEqual(try validator().policyBlockers(ghost, action: .deletePermanently, options: o), [])
        XCTAssertEqual(try validator().policyBlockers(ghost, action: .deletePermanently, options: .init()),
                       [.permanentDeleteDisabled])
    }
}
