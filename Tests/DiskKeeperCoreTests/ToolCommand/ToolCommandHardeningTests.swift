import Darwin
import XCTest
@testable import DiskKeeperCore

/// #123 items 1–3. Fake tools in temp dirs only.
final class ToolCommandHardeningTests: XCTestCase {
    private var fx: TemporaryDirectory!
    private let runner = FakeToolRunner()
    override func setUpWithError() throws { fx = try TemporaryDirectory() }
    override func tearDown() { fx = nil }

    private func performer(exe: String, intentLog: AuditLog? = nil, runner: FakeToolRunner? = nil) -> ToolCommandPerformer {
        let env = PathEnvironment(home: fx.path("home"), temporaryDirectory: fx.path("tmp"), variables: [:])
        return ToolCommandPerformer(registry: ToolCommandRegistry(specs: [ToolFixtures.spec(exe: exe)]),
                                    context: ToolCommandContext(environment: env, runner: runner ?? self.runner),
                                    intentLog: intentLog)
    }

    func testSymlinkThroughGroupWritableDirectoryIsRefused() throws {
        let exe = try ToolFixtures.writeTool(in: fx)
        let linkDir = fx.path("links")
        try FileManager.default.createDirectory(atPath: linkDir, withIntermediateDirectories: true)
        chmod(linkDir, 0o775)
        let link = linkDir + "/adk-test"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: exe)
        guard case .failure(.unsafeOwnerOrMode(let dir)) = ToolExecutableResolver().resolve(candidates: [link], toolName: "adk-test") else {
            return XCTFail("resolved through a group-writable hop directory")
        }
        XCTAssertEqual(dir, linkDir)
        chmod(linkDir, 0o755)
        guard case .success = ToolExecutableResolver().resolve(candidates: [link], toolName: "adk-test") else { return XCTFail("safe chain refused") }
    }

    func testBasenameMismatchIsRefused() throws {
        let exe = try ToolFixtures.writeTool(in: fx, name: "evil")
        guard case .failure(.nameMismatch(let expected, let actual)) = ToolExecutableResolver().resolve(candidates: [exe], toolName: "docker") else {
            return XCTFail("accepted")
        }
        XCTAssertEqual(expected, "docker"); XCTAssertEqual(actual, "evil")
        // A link named like the tool that points at another binary is the same thing.
        let link = fx.path("docker")
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: exe)
        guard case .failure(.nameMismatch) = ToolExecutableResolver().resolve(candidates: [link], toolName: "docker") else { return XCTFail("link accepted") }
    }

    func testRewritingTheToolBetweenPlanAndExecuteIsRefused() async throws {
        let exe = try ToolFixtures.writeTool(in: fx)
        let p = performer(exe: exe)
        let (blockers, snap) = await p.planCheck(ToolFixtures.virtualItem(), probes: ToolProbeCache())
        XCTAssertTrue(blockers.isEmpty)
        XCTAssertNotNil(snap?.executableIdentity)
        // Same name and path, different content (size changes).
        try Data("#!/bin/sh\necho swapped; exit 0\n".utf8).write(to: URL(fileURLWithPath: exe))
        let run = await p.execute(ToolFixtures.virtualItem(), expected: snap)
        guard case .blocked(let b, _) = run else { return XCTFail("ran a rewritten tool") }
        XCTAssertEqual(b, [.identityChanged])
        XCTAssertTrue(runner.calls.isEmpty)
    }

    func testUnchangedToolStillRuns() async throws {
        let exe = try ToolFixtures.writeTool(in: fx)
        let p = performer(exe: exe)
        let (_, snap) = await p.planCheck(ToolFixtures.virtualItem(), probes: ToolProbeCache())
        guard case .ran = await p.execute(ToolFixtures.virtualItem(), expected: snap) else { return XCTFail("blocked") }
        XCTAssertEqual(runner.calls.count, 1)
    }

    /// The intent line is on disk before the command starts, so a crash (here: a runner that throws) leaves it.
    func testIntentLineIsWrittenBeforeRunAndSurvivesACrash() async throws {
        final class CrashingRunner: ToolProcessRunning, @unchecked Sendable {
            let auditURL: URL
            var intentSeenAtStart = false
            init(_ u: URL) { auditURL = u }
            func run(executable: URL, arguments: [String], environment: [String: String], timeout: Duration,
                     maxStdout: Int) async throws -> ToolCommandResult {
                intentSeenAtStart = ((try? AuditLog.read(auditURL)) ?? []).contains { $0.result == "intent" }
                struct Crash: Error {}
                throw Crash()
            }
        }
        let exe = try ToolFixtures.writeTool(in: fx)
        let url = URL(fileURLWithPath: fx.path("audit/audit.jsonl"))
        let crashing = CrashingRunner(url)
        let env = PathEnvironment(home: fx.path("home"), temporaryDirectory: fx.path("tmp"), variables: [:])
        let p = ToolCommandPerformer(registry: ToolCommandRegistry(specs: [ToolFixtures.spec(exe: exe)]),
                                     context: ToolCommandContext(environment: env, runner: crashing),
                                     intentLog: AuditLog(fileURL: url))
        let (_, snap) = await p.planCheck(ToolFixtures.virtualItem(), probes: ToolProbeCache())
        _ = await p.execute(ToolFixtures.virtualItem(), expected: snap)
        XCTAssertTrue(crashing.intentSeenAtStart)
        let records = try AuditLog.read(url)
        XCTAssertEqual(records.map(\.result), ["intent"])
        XCTAssertEqual(records[0].command, snap?.command)
    }

    /// N3: no intent line, no run: reported as blocked ("not run"), never as a failed run.
    func testUnwritableIntentLogMeansNotRun() async throws {
        let exe = try ToolFixtures.writeTool(in: fx)
        try Data("x".utf8).write(to: URL(fileURLWithPath: fx.path("file")))
        let log = AuditLog(fileURL: URL(fileURLWithPath: fx.path("file/audit.jsonl")))   // parent is a regular file
        let p = performer(exe: exe, intentLog: log)
        let (_, snap) = await p.planCheck(ToolFixtures.virtualItem(), probes: ToolProbeCache())
        switch await p.execute(ToolFixtures.virtualItem(), expected: snap) {
        case .blocked(let b, _): XCTAssertEqual(b, [.auditIntentNotWritten])
        case .ran(let o, _): XCTFail("reported as run: \(o)")
        }
        XCTAssertTrue(runner.calls.isEmpty)
    }

    /// Exact pairing: an outcome carrying an intent's id settles that intent, not the nearest one; `skipped` included.
    func testIntentIDPairingIsExact() throws {
        func rec(_ result: String, id: UUID?, at t: TimeInterval) -> AuditRecord {
            AuditRecord(timestamp: Date(timeIntervalSince1970: t), runID: UUID(), itemID: "a", path: "/p", bytes: 5,
                        action: .deletePermanently, result: result, trashPath: nil, ruleID: "r", tool: "adktest", reasons: [],
                        error: nil, command: ["/x/adk-test", "rm", "a"], intentID: id)
        }
        let first = UUID(), second = UUID()
        let enc = DiskKeeperJSON.makeEncoder()
        var data = Data()
        for r in [rec("intent", id: first, at: 1), rec("intent", id: second, at: 2),
                  rec("ran", id: first, at: 3), rec("skipped", id: second, at: 4)] {
            data.append(try enc.encode(r)); data.append(0x0A)
        }
        let results = AuditHistoryReader.parse(data).runs.flatMap { $0.records }.map(\.result).sorted()
        XCTAssertEqual(results, ["ran", "skipped"])
        // The outcome of the first intent alone leaves the second one visible.
        var only = Data()
        for r in [rec("intent", id: first, at: 1), rec("intent", id: second, at: 2), rec("ran", id: first, at: 3)] {
            only.append(try enc.encode(r)); only.append(0x0A)
        }
        let left = AuditHistoryReader.parse(only).runs.flatMap { $0.records }
        XCTAssertEqual(left.map(\.result).sorted(), ["intent", "ran"])
        XCTAssertEqual(left.first { $0.result == "intent" }?.intentID, second)
    }

    /// A symlink cycle (and a chain longer than the hop cap) is refused, not followed forever.
    func testSymlinkCycleAndHopCapAreRefused() throws {
        let a = fx.path("cyc-a"), b = fx.path("cyc-b")
        try FileManager.default.createSymbolicLink(atPath: a, withDestinationPath: b)
        try FileManager.default.createSymbolicLink(atPath: b, withDestinationPath: a)
        guard case .failure = ToolExecutableResolver().resolve(candidates: [a], toolName: "cyc-a") else { return XCTFail("cycle resolved") }

        let exe = try ToolFixtures.writeTool(in: fx)
        var target = exe
        for i in 0..<45 {
            let link = fx.path("hop\(i)/adk-test")
            try FileManager.default.createDirectory(atPath: fx.path("hop\(i)"), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)
            target = link
        }
        guard case .failure = ToolExecutableResolver().resolve(candidates: [target], toolName: "adk-test") else { return XCTFail("45 hops resolved") }
    }

    func testHistoryToleratesIntentWithoutOutcomeAndSettlesPaired() throws {
        func rec(_ result: String, item: String, at t: TimeInterval) -> AuditRecord {
            AuditRecord(timestamp: Date(timeIntervalSince1970: t), runID: UUID(), itemID: item, path: "/p", bytes: 5,
                        action: .deletePermanently, result: result, trashPath: nil, ruleID: "r", tool: "adktest", reasons: [],
                        error: nil, command: ["/x/adk-test", "rm", item])
        }
        let enc = DiskKeeperJSON.makeEncoder()
        var data = Data()
        for r in [rec("intent", item: "a", at: 1), rec("intent", item: "b", at: 2), rec("ran", item: "a", at: 3)] {
            data.append(try enc.encode(r)); data.append(0x0A)
        }
        let h = AuditHistoryReader.parse(data)
        XCTAssertEqual(h.malformedLines, 0)
        let results = h.runs.flatMap { $0.records }.map { "\($0.itemID):\($0.result)" }.sorted()
        XCTAssertEqual(results, ["a:ran", "b:intent"])
        XCTAssertEqual(h.runs.reduce(0) { $0 + $1.items }, 1)
    }
}
