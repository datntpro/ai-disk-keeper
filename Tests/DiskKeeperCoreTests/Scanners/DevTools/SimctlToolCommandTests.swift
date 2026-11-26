import Darwin
import XCTest
@testable import DiskKeeperCore

final class SimctlToolCommandTests: XCTestCase {
    private typealias F = SimctlFixture
    private let listed = "simctl list devices unavailable --json"

    private func ready(deletes: Bool = true) throws -> SimctlFixture {
        let fx = try SimctlFixture()
        try fx.device(F.udidA)
        try fx.installXcrun(listJSON: fx.listJSON([(F.udidA, false, "Shutdown", nil)]), deletes: deletes)
        return fx
    }

    /// The item as the real scanner emits it (real measured size and mtime), so the change check passes.
    private func scanned(_ fx: SimctlFixture) async throws -> ScanItem {
        let items = try await fx.scan().items
        // Forget the scan's own call: the tests below assert only what plan and execute run.
        try? FileManager.default.removeItem(atPath: fx.log); try? FileManager.default.removeItem(atPath: fx.marker)
        return try XCTUnwrap(items.first { $0.path.hasSuffix(F.udidA) })
    }

    private func engine(_ fx: SimctlFixture) throws -> (CleanupEngine, URL) {
        let audit = URL(fileURLWithPath: fx.home.abs("$TMP/audit.jsonl"))
        let guardian = try ProtectedPaths(homeDirectory: fx.home.home, temporaryDirectory: fx.home.tempDir)
        let trash = URL(fileURLWithPath: fx.home.abs("$TMP/Trash"))
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        return (CleanupEngine(pathGuard: guardian, auditLog: AuditLog(fileURL: audit), trash: DirectoryTrash(root: trash),
                              runningApps: FakeRunningApps(), toolCommands: fx.performer()), audit)
    }

    // MARK: Registry

    func testExactBindingMatches() throws {
        let fx = try ready()
        let m = try fx.registry().match(fx.item(F.udidA), environment: fx.env).get()
        XCTAssertEqual(m.argv, ["simctl", "delete", F.udidA])
        XCTAssertEqual(m.spec.id, "simctl.delete")
    }

    func testRefusals() throws {
        let fx = try ready()
        let reg = fx.registry()
        func refused(_ item: ScanItem, _ why: String) {
            if case .success = reg.match(item, environment: fx.env) { XCTFail("accepted: \(why)") }
        }
        refused(fx.item(F.udidA, args: ["simctl", "delete", "unavailable"]), "delete unavailable")
        refused(fx.item(F.udidA, args: ["simctl", "erase", "all"]), "erase all")
        refused(fx.item(F.udidA, args: ["simctl", "delete", "all"]), "delete all")
        refused(fx.item(F.udidA, args: ["simctl", "delete", F.udidA, F.udidB]), "two UDIDs")
        refused(fx.item(F.udidA, args: ["simctl", "delete", F.udidB]), "UDID != folder")
        refused(fx.item(F.udidA, args: ["simctl", "delete", F.udidA.lowercased()]), "lowercase")
        refused(fx.item(F.udidA, args: ["simctl", "delete", "-f"]), "flag")
        refused(fx.item(F.udidA, rule: "dev-tools.simulator.unavailable"), "non-reserved ruleID (JSON rule)")
        refused(fx.item(F.udidA, rule: "tool.other"), "ruleID not in spec")
        var outside = fx.item(F.udidA)
        outside = ScanItem(url: URL(fileURLWithPath: fx.home.abs("Library/Developer/CoreSimulator/\(F.udidA)")),
                           displayName: "x", tool: "dev-caches", category: .systemJunk, sizeAllocated: 1, sizeLogical: 1,
                           fileCount: 1, lastModified: nil, tier: .review, explanation: "x", ruleID: SimctlToolCommands.ruleID,
                           cleanupMethod: outside.cleanupMethod)
        refused(outside, "folder outside the devices root")
        let nested = ScanItem(url: URL(fileURLWithPath: "\(fx.devices)/\(F.udidA)/data"), displayName: "x", tool: "dev-caches",
                              category: .systemJunk, sizeAllocated: 1, sizeLogical: 1, fileCount: 1, lastModified: nil,
                              tier: .review, explanation: "x", ruleID: SimctlToolCommands.ruleID, cleanupMethod: outside.cleanupMethod)
        refused(nested, "nested path")
    }

    func testTheReadSpecIsNeverMatchedForCleanup() throws {
        let fx = try ready()
        refusedCleanup(fx, ["simctl", "list", "devices", "unavailable", "--json"])
    }

    private func refusedCleanup(_ fx: SimctlFixture, _ args: [String]) {
        if case .success = fx.registry().match(fx.item(F.udidA, args: args), environment: fx.env) { XCTFail("read spec ran as cleanup") }
    }

    func testBuiltInRegistryHasExactlyTheTwoSpecsAndNoForbiddenWords() {
        let specs = ToolCommandRegistry.builtIn.specs.filter { $0.command == "xcrun" }
        XCTAssertEqual(Set(specs.map(\.id)), ["simctl.list.unavailable", "simctl.delete"])
        XCTAssertEqual(specs.filter(\.isDestructive).count, 1)
        XCTAssertFalse(ToolCommandRegistry.builtIn.specs.contains { $0.command == "brew" })
        let forbidden: Set<String> = ["erase", "all", "shutdown", "boot", "runtime", "--set", "-f", "--force"]
        for spec in specs {
            for case .literal(let s) in spec.template {
                XCTAssertFalse(forbidden.contains(s), "forbidden literal \(s)")
                XCTAssertFalse(s.hasPrefix("--set"))
            }
        }
        // "unavailable" is only ever the filter of the read-only list, never an argument of delete.
        let delete = specs.first { $0.id == "simctl.delete" }
        XCTAssertEqual(delete?.template.count, 3)
        XCTAssertEqual(specs.flatMap(\.ruleIDs).filter { !$0.hasPrefix("tool.") }, [])
    }

    func testSpecEnvironmentIsExactlyFourKeysAndExecutableIsXcrunOnly() throws {
        let fx = try ready()
        let spec = SimctlToolCommands.makeSpecs(developer: fx.developer).first { $0.id == "simctl.delete" }!
        let ctx = ToolCommandContext(environment: fx.env, runner: FakeToolRunner())
        let env = try XCTUnwrap(spec.environment(ctx, fx.item(F.udidA)))
        XCTAssertEqual(Set(env.keys), ["PATH", "LC_ALL", "HOME", "DEVELOPER_DIR"])
        XCTAssertEqual(env["DEVELOPER_DIR"], fx.devDir)
        XCTAssertEqual(spec.executable(ctx, fx.item(F.udidA)).candidates, ["/usr/bin/xcrun"])
    }

    // MARK: Engine

    func testPlanIsExecutableWithTheVerbatimCommandAndNothingRunsToDelete() async throws {
        let fx = try ready()
        let (eng, _) = try engine(fx)
        let plan = await eng.plan([try await scanned(fx)])
        let e = plan.entries[0]
        XCTAssertTrue(e.isExecutable, "\(e.blockers)")
        let snap = try XCTUnwrap(e.toolCommand)
        XCTAssertEqual(ToolCommandDisplay.line(snap), "xcrun simctl delete \(F.udidA)")
        XCTAssertEqual(fx.argvLog, [listed], "plan only lists")
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(fx.devices)/\(F.udidA)"))
    }

    func testExecuteListsThenDeletesAndAudits() async throws {
        let fx = try ready()
        let (eng, audit) = try engine(fx)
        let plan = await eng.plan([try await scanned(fx)])
        let report = try await eng.execute(plan)
        guard case .ranCommand(0) = report.results[0].outcome else { return XCTFail("\(report.results[0].outcome)") }
        XCTAssertEqual(fx.argvLog, [listed, listed, "simctl delete \(F.udidA)"], "plan probe, fresh execute probe, delete")
        XCTAssertFalse(FileManager.default.fileExists(atPath: "\(fx.devices)/\(F.udidA)"))
        let rec = try XCTUnwrap(AuditLog.read(audit).first)
        XCTAssertEqual(rec.result, "ran")
        XCTAssertEqual(rec.exitStatus, 0)
        XCTAssertEqual(rec.command?.suffix(3).map { $0 }, ["simctl", "delete", F.udidA])
        XCTAssertTrue(rec.command?.first?.hasSuffix("/xcrun") == true)
    }

    func testDeviceBecameAvailableBetweenPlanAndExecuteSkipsWithoutDeleting() async throws {
        let fx = try ready()
        let (eng, _) = try engine(fx)
        let plan = await eng.plan([try await scanned(fx)])
        XCTAssertTrue(plan.entries[0].isExecutable)
        try fx.installXcrun(listJSON: fx.listJSON([(F.udidA, true, "Shutdown", nil)]))
        let report = try await eng.execute(plan)
        guard case .skipped(let b) = report.results[0].outcome else { return XCTFail("\(report.results[0].outcome)") }
        XCTAssertEqual(b, [.inUseByTool(detail: "simulator is available again")])
        XCTAssertFalse(fx.argvLog.contains { $0.hasPrefix("simctl delete") })
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(fx.devices)/\(F.udidA)"))
    }

    func testBootedAtExecuteSkips() async throws {
        let fx = try ready()
        let (eng, _) = try engine(fx)
        let plan = await eng.plan([try await scanned(fx)])
        try fx.installXcrun(listJSON: fx.listJSON([(F.udidA, false, "Booted", nil)]))
        let report = try await eng.execute(plan)
        guard case .skipped(let b) = report.results[0].outcome else { return XCTFail("\(report.results[0].outcome)") }
        XCTAssertEqual(b, [.inUseByTool(detail: "simulator is running")])
    }

    func testExitZeroButFolderRemainsIsAFailure() async throws {
        let fx = try ready(deletes: false)
        let (eng, _) = try engine(fx)
        let plan = await eng.plan([try await scanned(fx)])
        let report = try await eng.execute(plan)
        guard case .failed(let why) = report.results[0].outcome else { return XCTFail("\(report.results[0].outcome)") }
        XCTAssertEqual(why, "simctl reported success but the simulator folder is still there")
    }

    func testNoDeveloperDirectoryMeansToolUnavailableAndXcrunNeverLaunched() async throws {
        let fx = try ready()
        let item = try await scanned(fx)
        fx.hasDeveloperDir = false
        let (eng, _) = try engine(fx)
        let plan = await eng.plan([item])
        XCTAssertEqual(plan.entries[0].blockers, [.toolUnavailable(tool: "xcrun")])
        XCTAssertFalse(fx.launched)
    }

    func testForgedEraseAllIsRefusedAndNeverRun() async throws {
        let fx = try ready()
        let (eng, _) = try engine(fx)
        let plan = await eng.plan([fx.item(F.udidA, args: ["simctl", "erase", "all"])])
        XCTAssertFalse(plan.entries[0].isExecutable)
        XCTAssertTrue(plan.entries[0].blockers.contains { if case .toolCommandNotAllowed = $0 { return true } else { return false } })
        XCTAssertFalse(fx.launched)
    }

    func testJSONRuleItemWithSimulatorCommandIsRefused() async throws {
        let fx = try ready()
        let (eng, _) = try engine(fx)
        let plan = await eng.plan([fx.item(F.udidA, rule: "dev-caches.simulator-fake")])
        XCTAssertFalse(plan.entries[0].isExecutable)
        XCTAssertFalse(fx.launched)
    }

    func testXcodeSelectLiveHelperRejectsMissingAndFailingTools() throws {
        let fx = try SimctlFixture()
        XCTAssertNil(SimctlEnvironment.askXcodeSelect(URL(fileURLWithPath: "/nonexistent/xcode-select")))
        let bad = URL(fileURLWithPath: fx.home.abs("$TMP/xs-bad"))
        try "#!/bin/sh\necho /definitely/not/here\n".write(to: bad, atomically: true, encoding: .utf8)
        chmod(bad.path, 0o755)
        XCTAssertNil(SimctlEnvironment.askXcodeSelect(bad))
        let good = URL(fileURLWithPath: fx.home.abs("$TMP/xs-good"))
        try "#!/bin/sh\necho '\(fx.devDir)'\n".write(to: good, atomically: true, encoding: .utf8)
        chmod(good.path, 0o755)
        XCTAssertEqual(SimctlEnvironment.askXcodeSelect(good), fx.devDir)
    }
}
