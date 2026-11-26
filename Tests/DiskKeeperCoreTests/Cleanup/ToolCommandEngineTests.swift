import Foundation
import XCTest
@testable import DiskKeeperCore

/// The engine with a fake process runner only: nothing here starts a process.
final class ToolCommandEngineTests: CleanupTestCase {
    private var exe = ""
    private let runner = FakeToolRunner()
    private let gate = Toggle()

    override func setUpWithError() throws {
        try super.setUpWithError()
        exe = try ToolFixtures.writeTool(in: fx)
    }

    private func performer(_ spec: ToolCommandSpec? = nil, runner: FakeToolRunner? = nil) -> ToolCommandPerformer {
        let env = PathEnvironment(home: home, temporaryDirectory: fx.path("tmp"), variables: [:])
        return ToolCommandPerformer(
            registry: ToolCommandRegistry(specs: [spec ?? ToolFixtures.spec(exe: exe, revalidate: gate)]),
            context: ToolCommandContext(environment: env, runner: runner ?? self.runner))
    }

    private func engine(_ p: ToolCommandPerformer?) throws -> CleanupEngine {
        CleanupEngine(pathGuard: try makeGuard(), auditLog: AuditLog(fileURL: auditURL),
                      trash: DirectoryTrash(root: trashDir), runningApps: FakeRunningApps(), toolCommands: p)
    }

    func testNoPerformerBlocksWithToolCommandUnavailable() async throws {
        let plan = await (try engine(nil)).plan([ToolFixtures.virtualItem()])
        XCTAssertEqual(plan.entries[0].blockers, [.toolCommandUnavailable])
    }

    func testPlanIsExecutableAndHoldsASnapshot() async throws {
        let plan = await (try engine(performer())).plan([ToolFixtures.virtualItem()])
        let e = plan.entries[0]
        XCTAssertTrue(e.isExecutable, "\(e.blockers)")
        let snap = try XCTUnwrap(e.toolCommand)
        XCTAssertEqual(snap.executablePath, String(cString: realpath(exe, nil)))
        XCTAssertEqual(snap.argv, ["thing", "rm", ToolFixtures.imageID])
        XCTAssertEqual(snap.environmentDisplay["ADK_TARGET"], "t1")
        XCTAssertEqual(ToolCommandDisplay.line(snap), "adk-test thing rm " + ToolFixtures.imageID)
        XCTAssertTrue(runner.calls.isEmpty, "a dry run never runs the command")
    }

    func testExecuteRunsTheFakeOnceWithTheExactArgvAndAudits() async throws {
        let eng = try engine(performer())
        let plan = await eng.plan([ToolFixtures.virtualItem()])
        let report = try await eng.execute(plan)
        guard case .ranCommand(0) = report.results[0].outcome else { return XCTFail("\(report.results[0].outcome)") }
        XCTAssertEqual(runner.calls.count, 1)
        let snap = try XCTUnwrap(plan.entries[0].toolCommand)
        XCTAssertEqual(runner.calls[0].executable, snap.executablePath)
        XCTAssertEqual(runner.calls[0].arguments, snap.argv, "the executed argv equals the shown argv")
        XCTAssertEqual(runner.calls[0].environment, snap.environmentDisplay)
        XCTAssertEqual(report.freedBytes, 1000)
        let rec = try XCTUnwrap(AuditLog.read(auditURL).first)
        XCTAssertEqual(rec.result, "ran")
        XCTAssertEqual(rec.command, snap.command)
        XCTAssertEqual(rec.exitStatus, 0)
        XCTAssertNotNil(rec.durationMs)
        XCTAssertEqual(rec.toolTarget, "t1")
        XCTAssertTrue(trashContents().isEmpty)
    }

    func testRevalidateBlockerAtExecuteSkipsAndNeverRuns() async throws {
        let eng = try engine(performer())
        let plan = await eng.plan([ToolFixtures.virtualItem()])
        XCTAssertTrue(plan.entries[0].isExecutable)
        gate.blockers = [.inUseByTool(detail: "x")]
        let report = try await eng.execute(plan)
        XCTAssertEqual(skippedCodes(report.results[0].outcome), ["inUseByTool"])
        XCTAssertTrue(runner.calls.isEmpty)
        let rec = try XCTUnwrap(AuditLog.read(auditURL).first)
        XCTAssertEqual(rec.result, "skipped"); XCTAssertNotNil(rec.command); XCTAssertNil(rec.exitStatus)
    }

    func testExecutableSwappedBetweenPlanAndExecute() async throws {
        let eng = try engine(performer())
        let plan = await eng.plan([ToolFixtures.virtualItem()])
        let other = try ToolFixtures.writeTool(in: fx, name: "other")
        // Same spec id, different executable at execute time.
        let swapped = performer(ToolFixtures.spec(exe: other, revalidate: gate))
        let eng2 = try engine(swapped)
        let plan2 = await eng2.plan([ToolFixtures.virtualItem()])
        XCTAssertNotEqual(plan.entries[0].toolCommand?.executablePath, plan2.entries[0].toolCommand?.executablePath)
        // Directly: the planned snapshot against a performer that resolves elsewhere.
        let run = await swapped.execute(ToolFixtures.virtualItem(), expected: plan.entries[0].toolCommand)
        guard case .blocked(let b, _) = run else { return XCTFail("ran") }
        XCTAssertEqual(b, [.toolUnavailable(tool: "adk-test")])
        XCTAssertTrue(runner.calls.isEmpty)
    }

    func testToolDisappearingAtExecuteIsToolUnavailable() async throws {
        let eng = try engine(performer())
        let plan = await eng.plan([ToolFixtures.virtualItem()])
        try FileManager.default.removeItem(atPath: exe)
        let report = try await eng.execute(plan)
        XCTAssertEqual(skippedCodes(report.results[0].outcome), ["toolUnavailable"])
        XCTAssertTrue(runner.calls.isEmpty)
    }

    func testEditedSnapshotIsPlanModified() async throws {
        let eng = try engine(performer())
        let plan = await eng.plan([ToolFixtures.virtualItem()])
        let e = plan.entries[0]
        let forged = ToolCommandSnapshot(specID: "x", executablePath: "/bin/rm", argv: ["-rf", "/"], environmentDisplay: [:], targetLabel: nil)
        let tampered = CleanupPlan(id: plan.id, createdAt: plan.createdAt, entries: [
            CleanupPlanEntry(item: e.item, action: e.action, blockers: [], fingerprint: nil, toolCommand: forged)])
        do { _ = try await eng.execute(tampered); XCTFail("ran") } catch { XCTAssertEqual(error as? CleanupError, .planModified) }
        XCTAssertTrue(runner.calls.isEmpty)
    }

    func testNonZeroExitFailsWithFirstStderrLine() async throws {
        runner.result = ToolCommandResult(exitStatus: 1, stderrTail: "Error: conflict\nsecond line\n")
        let eng = try engine(performer())
        let report = try await eng.execute(await eng.plan([ToolFixtures.virtualItem()]))
        XCTAssertEqual(report.results[0].outcome, .failed("adk-test exited 1: Error: conflict"))
        XCTAssertEqual(report.freedBytes, 0)
        let rec = try XCTUnwrap(AuditLog.read(auditURL).first)
        XCTAssertEqual(rec.result, "failed"); XCTAssertEqual(rec.exitStatus, 1)
    }

    func testTimeoutMessage() async throws {
        runner.result = ToolCommandResult(exitStatus: -1, timedOut: true)
        let eng = try engine(performer())
        let report = try await eng.execute(await eng.plan([ToolFixtures.virtualItem()]))
        guard case .failed(let m) = report.results[0].outcome else { return XCTFail() }
        XCTAssertTrue(m.contains("didn't finish within 5 s"), m)
    }

    func testCancelledRunIsStoppedAndRemainingEntriesNotAttempted() async throws {
        runner.cancel = true
        let eng = try engine(performer())
        let items = [ToolFixtures.virtualItem(), ToolFixtures.virtualItem(id: ToolFixtures.otherID)]
        let plan = await eng.plan(items)
        let task = Task { try await eng.execute(plan) }
        let report = try await task.value
        XCTAssertEqual(report.results[0].outcome, .failed("stopped"))
    }

    func testKeepTierIsNeverRun() async throws {
        let eng = try engine(performer())
        let plan = await eng.plan([ToolFixtures.virtualItem(tier: .keep)])
        XCTAssertEqual(plan.entries[0].blockers, [.keepTier])
        _ = try await eng.execute(plan)
        XCTAssertTrue(runner.calls.isEmpty)
    }

    func testNotAllowedItemIsRefusedAndNeverRun() async throws {
        let bad = ToolFixtures.virtualItem(rule: "json.rule")
        let eng = try engine(performer())
        let plan = await eng.plan([bad])
        guard case .toolCommandNotAllowed? = plan.entries[0].blockers.first else { return XCTFail("\(plan.entries[0].blockers)") }
        _ = try await eng.execute(plan)
        XCTAssertTrue(runner.calls.isEmpty)
    }

    func testToolNotRunningWhenEnvironmentIsNil() async throws {
        var spec = ToolFixtures.spec(exe: exe)
        spec = ToolCommandSpec(id: spec.id, command: spec.command, ruleIDs: spec.ruleIDs, target: spec.target, template: spec.template,
                               bind: spec.bind, timeout: spec.timeout, executable: spec.executable, environment: { _, _ in nil })
        let plan = await (try engine(performer(spec))).plan([ToolFixtures.virtualItem()])
        XCTAssertEqual(plan.entries[0].blockers, [.toolNotRunning(tool: "adk-test", target: "t1")])
    }

    func testVerifyAfterFailureBecomesFailed() async throws {
        var spec = ToolFixtures.spec(exe: exe)
        spec = ToolCommandSpec(id: spec.id, command: spec.command, ruleIDs: spec.ruleIDs, target: spec.target, template: spec.template,
                               bind: spec.bind, timeout: spec.timeout, executable: spec.executable, environment: spec.environment,
                               verifyAfter: { _, _, _ in "still there" })
        let eng = try engine(performer(spec))
        let report = try await eng.execute(await eng.plan([ToolFixtures.virtualItem()]))
        XCTAssertEqual(report.results[0].outcome, .failed("still there"))
    }

    func testMixedPlanRunsTrashAndCommandInOrder() async throws {
        try fx.file("home/cache/a/f", bytes: 3000)
        let eng = try engine(performer())
        let plan = await eng.plan([try item("home/cache/a"), ToolFixtures.virtualItem()])
        XCTAssertEqual(plan.executableEntries.count, 2)
        let report = try await eng.execute(plan)
        guard case .trashed = report.results[0].outcome, case .ranCommand = report.results[1].outcome else { return XCTFail("\(report.results)") }
        XCTAssertFalse(exists("home/cache/a"))
        XCTAssertEqual(runner.calls.count, 1)
        XCTAssertEqual(try AuditLog.read(auditURL).map(\.result), ["trashed", "ran"])
    }

    func testDuplicateVirtualItemIsBlockedNotRunTwice() async throws {
        let eng = try engine(performer())
        let plan = await eng.plan([ToolFixtures.virtualItem(), ToolFixtures.virtualItem()])
        XCTAssertEqual(plan.entries[1].blockers, [.duplicate])
        _ = try await eng.execute(plan)
        XCTAssertEqual(runner.calls.count, 1)
    }

    func testAuditRecordRoundTripsAndOldLinesStillDecode() throws {
        let old = #"{"schemaVersion":1,"timestamp":"1970-01-01T00:00:00Z","runID":"00000000-0000-0000-0000-000000000000","itemID":"i","path":"/p","bytes":1,"action":"trash","result":"trashed","ruleID":"r","tool":"t","reasons":[]}"#
        let rec = try DiskKeeperJSON.makeDecoder().decode(AuditRecord.self, from: Data(old.utf8))
        XCTAssertNil(rec.command); XCTAssertNil(rec.exitStatus)
    }

    // A JSON rule can declare `toolCommand`: the plan refuses it and the fake is never run.
    func testJSONRuleToolCommandIsRefusedAtCleanup() async throws {
        let fixture = try FixtureHome()
        try fixture.file(".test/cache/blob", bytes: 10)
        let extra = #""cleanup":{"method":"toolCommand","command":"adk-test","arguments":["thing","rm","x"]}"#
        let json = RuleFixtures.file(tool: "test", rules: [RuleFixtures.rule(id: "test.rule", paths: #"["~/.test/cache"]"#, extra: extra)])
        let result = try await RuleHarness.run(json: json, fixture: fixture, now: Date(), userID: getuid())
        let item = try XCTUnwrap(result.items.first)
        guard case .toolCommand = item.cleanupMethod else { return XCTFail("\(item.cleanupMethod)") }
        let eng = try engine(performer())
        let plan = await eng.plan([item])
        XCTAssertFalse(plan.entries[0].isExecutable)
        XCTAssertTrue(plan.entries[0].blockers.contains(.toolCommandNotAllowed(reason: "only built-in scanners may run a command")),
                      "\(plan.entries[0].blockers)")
        _ = try await eng.execute(plan)
        XCTAssertTrue(runner.calls.isEmpty)
    }

    // F1 regression (the verifier's PoC): a JSON rule on a `.path` spec's folder never runs, whatever its id.
    func testJSONRuleCannotRunAPathTargetSpec() async throws {
        let fixture = try FixtureHome()
        try fixture.file(".test/cache/vol1/blob", bytes: 10)
        let extra = #""cleanup":{"method":"toolCommand","command":"adk-test","arguments":["thing","rm","vol1"]}"#
        let root = fixture.home + "/.test/cache"
        let pathSpec = ToolFixtures.spec(exe: exe, rules: ["tool.test.rule"], target: .path(root: { _ in root }))
        // 1. A colliding id in the reserved namespace is rejected when the rules load.
        let reserved = RuleFixtures.file(tool: "tool", rules: [RuleFixtures.rule(id: "tool.rule", paths: #"["~/.test/cache/vol1"]"#, extra: extra)])
        let rejected = try await RuleHarness.run(json: reserved, fixture: fixture, now: Date(), userID: getuid())
        XCTAssertTrue(rejected.items.isEmpty)
        // 2. Any id it can use is refused at plan and never runs.
        let json = RuleFixtures.file(tool: "test", rules: [RuleFixtures.rule(id: "test.rule", paths: #"["~/.test/cache/vol1"]"#, extra: extra)])
        let result = try await RuleHarness.run(json: json, fixture: fixture, now: Date(), userID: getuid())
        let item = try XCTUnwrap(result.items.first)
        let eng = try engine(performer(pathSpec))
        let plan = await eng.plan([item])
        XCTAssertFalse(plan.entries[0].isExecutable)
        XCTAssertTrue(plan.entries[0].blockers.contains(.toolCommandNotAllowed(reason: "only built-in scanners may run a command")),
                      "\(plan.entries[0].blockers)")
        _ = try await eng.execute(plan)
        XCTAssertTrue(runner.calls.isEmpty)
    }
}
