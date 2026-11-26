import Darwin
import Foundation
import XCTest
@testable import DiskKeeperCore

final class TrashApplicationEngineTests: AppBundleTestCase {
    private let app = "tmp/Applications/Foo.app"

    private func planAndRun(_ engine: CleanupEngine, _ item: ScanItem, mutate: (() throws -> Void)? = nil)
        async throws -> (CleanupPlan, CleanupReport?) {
        let plan = await engine.plan([item])
        try mutate?()
        guard plan.entries[0].isExecutable || mutate != nil else { return (plan, nil) }
        return (plan, try await engine.execute(plan))
    }

    private func outcome(_ r: CleanupReport?) -> CleanupOutcome? { r?.results.first?.outcome }

    func testHappyPathTrashesExactlyTheBundleAndAudits() async throws {
        try makeApp(app)
        let e = try engine()
        let (plan, report) = try await planAndRun(e, appItem(app))
        XCTAssertTrue(plan.entries[0].isExecutable, "\(plan.entries[0].blockers)")
        XCTAssertNotNil(plan.entries[0].appBundle)
        guard case .trashed? = outcome(report) else { return XCTFail("\(String(describing: outcome(report)))") }
        XCTAssertEqual(trashRec.calls, [fx.path(app)])
        XCTAssertFalse(exists(app))
        let lines = try AuditLog.read(auditURL)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].action, .trash)
        XCTAssertEqual(lines[0].ruleID, "apps.bundle")
        XCTAssertEqual(lines[0].bundleID, "com.example.foo")
        XCTAssertEqual(lines[0].result, "trashed")
    }

    func testRefusedTable() async throws {
        let e = try engine()
        // Utilities, nested, symlinked, Apple, root-owned, running, renamed.
        try makeApp("tmp/Applications/Utilities/Foo.app")
        var p = await e.plan([appItem("tmp/Applications/Utilities/Foo.app")])
        XCTAssertEqual(p.entries[0].blockers, [.appBundleRefused(.notTopLevel)])

        try makeApp("tmp/Applications/Outer.app")
        try makeApp("tmp/Applications/Outer.app/Contents/Helpers/Foo.app")
        p = await e.plan([appItem("tmp/Applications/Outer.app/Contents/Helpers/Foo.app")])
        XCTAssertEqual(p.entries[0].blockers, [.appBundleRefused(.insideBundle)])

        let target = try makeApp("elsewhere/Foo.app")
        try FileManager.default.createSymbolicLink(atPath: fx.path("tmp/Applications/Link.app"), withDestinationPath: target)
        p = await e.plan([appItem("tmp/Applications/Link.app")])
        XCTAssertEqual(p.entries[0].blockers, [.appBundleRefused(.symlink)])

        try makeApp(app)
        probe.signature = .apple
        p = await e.plan([appItem(app)])
        XCTAssertEqual(p.entries[0].blockers, [.appBundleRefused(.appleOrSystem)])
        probe.signature = .developerID(teamID: "T")

        probe.setOwner(0, for: fx.path(app))
        p = await e.plan([appItem(app)])
        XCTAssertEqual(p.entries[0].blockers, [.requiresAdmin(bundleID: "com.example.foo")])
        probe.setOwner(UInt32(getuid()), for: fx.path(app))

        running.byID = true
        p = await e.plan([appItem(app)])
        XCTAssertEqual(p.entries[0].blockers, [.appRunning(bundleID: "com.example.foo")])
        running.byID = false

        try writePlist(app, id: "com.renamed.app")
        p = await e.plan([appItem(app)])
        XCTAssertEqual(p.entries[0].blockers, [.appBundleRefused(.bundleIDMismatch)])
        XCTAssertTrue(trashRec.calls.isEmpty)
    }

    func testRenamedBundleAfterPlanIsRefusedAtExecute() async throws {
        try makeApp(app)
        let e = try engine()
        let (_, report) = try await planAndRun(e, appItem(app)) { try self.writePlist(self.app, id: "com.renamed.app") }
        let codes = skippedCodes(try XCTUnwrap(outcome(report)))
        XCTAssertTrue(codes.contains("identityChanged") && codes.contains("appBundleRefused"), "\(codes)")
        XCTAssertTrue(trashRec.calls.isEmpty)
        XCTAssertTrue(exists(app))
    }

    // MARK: re-check at execute: nothing may reach the trash

    private func assertSkippedAtExecute(_ name: String, mutate: @escaping () throws -> Void,
                                        file: StaticString = #filePath, line: UInt = #line) async throws {
        try makeApp(app)
        let e = try engine()
        let (plan, report) = try await planAndRun(e, appItem(app), mutate: mutate)
        XCTAssertTrue(plan.entries[0].isExecutable, name, file: file, line: line)
        guard case .skipped? = outcome(report) else {
            return XCTFail("\(name): \(String(describing: outcome(report)))", file: file, line: line)
        }
        XCTAssertTrue(trashRec.calls.isEmpty, name, file: file, line: line)
    }

    func testExecuteRecheckAppStartsRunning() async throws {
        try await assertSkippedAtExecute("running") { self.running.byID = true }
    }
    func testExecuteRecheckHelperStartsInsideBundle() async throws {
        try await assertSkippedAtExecute("helper") { self.running.inside = true }
    }
    func testExecuteRecheckBundleBecomesSymlink() async throws {
        let target = try makeApp("elsewhere/Foo.app")
        try await assertSkippedAtExecute("symlink") {
            try FileManager.default.removeItem(atPath: self.fx.path(self.app))
            try FileManager.default.createSymbolicLink(atPath: self.fx.path(self.app), withDestinationPath: target)
        }
    }
    func testExecuteRecheckBundleReplacedWithNewInode() async throws {
        try await assertSkippedAtExecute("new inode") {
            try FileManager.default.removeItem(atPath: self.fx.path(self.app))
            try self.makeApp(self.app)
        }
    }
    func testExecuteRecheckOwnerChanges() async throws {
        try await assertSkippedAtExecute("owner") { self.probe.setOwner(0, for: self.fx.path(self.app)) }
    }
    func testExecuteRecheckParentSwappedForSymlink() async throws {
        try await assertSkippedAtExecute("parent symlink") {
            try FileManager.default.moveItem(atPath: self.fx.path("tmp/Applications"), toPath: self.fx.path("moved"))
            try FileManager.default.createSymbolicLink(atPath: self.fx.path("tmp/Applications"),
                                                       withDestinationPath: self.fx.path("moved"))
        }
    }

    // MARK: trash errors

    private func trashFailure(_ error: Error) async throws -> (CleanupOutcome, AuditRecord) {
        try makeApp(app)
        trashRec.failure = error
        let e = try engine()
        let (_, report) = try await planAndRun(e, appItem(app))
        let rec = try XCTUnwrap(try AuditLog.read(auditURL).first)
        return (try XCTUnwrap(outcome(report)), rec)
    }

    func testEPERMMapsToAppManagement() async throws {
        let (o, rec) = try await trashFailure(posixError(EPERM))
        XCTAssertEqual(o, .skipped([.needsAppManagementPermission(bundleID: "com.example.foo")]))
        XCTAssertEqual(rec.bundleID, "com.example.foo")
        XCTAssertEqual(rec.reasons, ["needsAppManagementPermission"])
    }
    func testEACCESMapsToRequiresAdmin() async throws {
        let (o, rec) = try await trashFailure(posixError(EACCES))
        XCTAssertEqual(o, .skipped([.requiresAdmin(bundleID: "com.example.foo")]))
        XCTAssertEqual(rec.bundleID, "com.example.foo")
    }
    func testOtherErrorIsFailed() async throws {
        let (o, rec) = try await trashFailure(posixError(EIO))
        guard case .failed = o else { return XCTFail("\(o)") }
        XCTAssertEqual(rec.result, "failed")
        XCTAssertEqual(rec.bundleID, "com.example.foo")
    }

    // MARK: fail closed

    func testNoPolicyBlocksEveryApp() async throws {
        try makeApp(app)
        let e = try engine(noPolicy: true)
        let plan = await e.plan([appItem(app)])
        XCTAssertEqual(plan.entries[0].blockers, [.appBundleRefused(.notApplicationMethod)])
    }

    func testUnknownRunningAppsBlocks() async throws {
        try makeApp(app)
        let e = try engine(apps: UnknownRunningApps())
        let plan = await e.plan([appItem(app)])
        XCTAssertTrue(plan.entries[0].blockers.contains(.appStateUnknown(bundleID: "com.example.foo")))
    }

    func testPlanTamperingOfAppBundleIsPlanModified() async throws {
        try makeApp(app)
        let e = try engine()
        let plan = await e.plan([appItem(app)])
        let entry = plan.entries[0]
        var fp = try XCTUnwrap(entry.appBundle)
        fp = AppBundleFingerprint(bundleDevice: fp.bundleDevice, bundleInode: fp.bundleInode + 1,
                                  infoPlistDevice: fp.infoPlistDevice, infoPlistInode: fp.infoPlistInode,
                                  infoPlistSize: fp.infoPlistSize, infoPlistModified: fp.infoPlistModified,
                                  bundleID: fp.bundleID, ownerUID: fp.ownerUID)
        let tampered = CleanupPlan(id: plan.id, createdAt: plan.createdAt, entries: [
            CleanupPlanEntry(item: entry.item, action: entry.action, blockers: entry.blockers,
                             fingerprint: entry.fingerprint, appBundle: fp)])
        do { _ = try await e.execute(tampered); XCTFail("executed") } catch {
            XCTAssertEqual(error as? CleanupError, .planModified)
        }
        XCTAssertTrue(trashRec.calls.isEmpty)
    }

    func testPermanentDeleteIsNeverUsedForApps() async throws {
        try makeApp(app)
        let remover = RecordingRemover()
        let e = try engine(options: CleanupOptions(requestPermanentDelete: true, permanentDeleteEnabled: true),
                           remover: remover)
        let plan = await e.plan([appItem(app)])
        XCTAssertTrue(plan.entries[0].blockers.contains(.appBundleRefused(.permanentDelete)))
        XCTAssertFalse(plan.entries[0].isExecutable)
        let report = try await e.execute(plan)
        XCTAssertTrue(remover.removed.isEmpty)
        XCTAssertTrue(trashRec.calls.isEmpty)
        XCTAssertTrue(exists(app))
        let rec = try XCTUnwrap(try AuditLog.read(auditURL).first)
        XCTAssertTrue(rec.reasons.contains("appBundleRefused:permanentDelete"), "\(rec.reasons)")
        _ = report
    }

    func testAuditDecodesOldLineWithoutBundleID() throws {
        let rec = AuditRecord(timestamp: Date(timeIntervalSince1970: 0), runID: UUID(), itemID: "i", path: "/x",
                              bytes: 1, action: .trash, result: "trashed", trashPath: nil, ruleID: "r",
                              tool: .claudeCode, reasons: [], error: nil, bundleID: "com.example.foo")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: DiskKeeperJSON.makeEncoder().encode(rec)) as? [String: Any])
        XCTAssertEqual(json["bundleID"] as? String, "com.example.foo")
        json["bundleID"] = nil
        let url = fx.url.appendingPathComponent("old.jsonl")
        var line = try JSONSerialization.data(withJSONObject: json)
        line.append(0x0A)
        try line.write(to: url)
        let r = try AuditLog.read(url)
        guard r.count == 1 else { return XCTFail("old line did not decode") }
        XCTAssertNil(r[0].bundleID)
        // A non-app record does not write the key at all.
        let plain = AuditRecord(timestamp: Date(), runID: UUID(), itemID: "i", path: "/x", bytes: 1, action: .trash,
                                result: "trashed", trashPath: nil, ruleID: "r", tool: .claudeCode, reasons: [], error: nil)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: DiskKeeperJSON.makeEncoder().encode(plain)) as? [String: Any])
        XCTAssertNil(obj["bundleID"])
    }

    func testDefaultRunningAppsConformanceIsUnknownInside() {
        struct Old: RunningAppChecking { func isRunning(bundleID: String) -> Bool? { false } }
        XCTAssertNil(Old().isAnyProcessRunning(insideBundleAt: "/x"))
    }
}
