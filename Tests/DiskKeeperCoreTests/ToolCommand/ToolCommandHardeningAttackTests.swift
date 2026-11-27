import Darwin
import XCTest
@testable import DiskKeeperCore

/// PR #143 verifier attack tests (fake tools in temp dirs only). Assertions state the DESIRED behaviour.
/// On 2db9120, tests marked [FAILS] fail; the others pass and are regression guards.
/// Drop into Tests/DiskKeeperCoreTests/ToolCommand/.
final class ToolCommandHardeningAttackTests: XCTestCase {
    private var fx: TemporaryDirectory!
    override func setUpWithError() throws { fx = try TemporaryDirectory() }
    override func tearDown() {
        for d in ["W", "G"] { chmod(fx.path(d), 0o755) }
        fx = nil
    }

    private func mkdir(_ rel: String, _ mode: mode_t = 0o755) throws -> String {
        let p = fx.path(rel)
        try FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
        chmod(p, mode)
        return p
    }

    private func performer(exe: String, runner: ToolProcessRunning, log: AuditLog? = nil) -> ToolCommandPerformer {
        let env = PathEnvironment(home: fx.path("home"), temporaryDirectory: fx.path("tmp"), variables: [:])
        return ToolCommandPerformer(registry: ToolCommandRegistry(specs: [ToolFixtures.spec(exe: exe)]),
                                    context: ToolCommandContext(environment: env, runner: runner), intentLog: log)
    }

    // MARK: Item 1 — resolver

    /// [FAILS] A *directory* symlink is a hop too. S/adk-test -> W/dl/adk-test, where `dl` (a symlink to a safe dir)
    /// lives in group-writable W: a W group member can repoint `dl`. Only file-symlink hops are checked today.
    func testDirectorySymlinkHopInGroupWritableDirIsRefused() throws {
        let exe = try ToolFixtures.writeTool(in: fx)              // fx/bin/adk-test, safe
        let w = try mkdir("W", 0o775)
        try FileManager.default.createSymbolicLink(atPath: w + "/dl", withDestinationPath: fx.path("bin"))
        let s = try mkdir("S")
        try FileManager.default.createSymbolicLink(atPath: s + "/adk-test", withDestinationPath: w + "/dl/adk-test")
        _ = exe
        guard case .failure(.unsafeOwnerOrMode) = ToolExecutableResolver().resolve(candidates: [s + "/adk-test"], toolName: "adk-test") else {
            return XCTFail("resolved through a directory symlink that sits in a group-writable dir")
        }
    }

    /// [FAILS] Same gap with no file symlink at all: the candidate's own path goes through a dir symlink in W.
    func testCandidatePathThroughDirSymlinkInWorldWritableDirIsRefused() throws {
        _ = try ToolFixtures.writeTool(in: fx)
        let w = try mkdir("W", 0o777)
        try FileManager.default.createSymbolicLink(atPath: w + "/dl", withDestinationPath: fx.path("bin"))
        guard case .failure(.unsafeOwnerOrMode) = ToolExecutableResolver().resolve(candidates: [w + "/dl/adk-test"], toolName: "adk-test") else {
            return XCTFail("resolved a candidate whose path crosses a world-writable dir via a dir symlink")
        }
    }

    /// A hop directory owned by another user is refused (simulated: resolver's userID is someone else's).
    func testHopDirectoryOwnedByAnotherUserIsRefused() throws {
        let exe = try ToolFixtures.writeTool(in: fx)
        let s = try mkdir("S")
        try FileManager.default.createSymbolicLink(atPath: s + "/adk-test", withDestinationPath: exe)
        guard case .failure(.unsafeOwnerOrMode(let d)) = ToolExecutableResolver(userID: getuid() &+ 4242)
            .resolve(candidates: [s + "/adk-test"], toolName: "adk-test") else { return XCTFail("accepted") }
        XCTAssertTrue(d.hasSuffix("/S"), d)
    }

    /// Group-writable hop deep in a chain (3 links, relative targets with ..) is found.
    func testDeepRelativeChainWithWritableMiddleHopIsRefused() throws {
        _ = try ToolFixtures.writeTool(in: fx)
        _ = try mkdir("A"); _ = try mkdir("G", 0o775); _ = try mkdir("C")
        try FileManager.default.createSymbolicLink(atPath: fx.path("A/adk-test"), withDestinationPath: "../G/adk-test")
        try FileManager.default.createSymbolicLink(atPath: fx.path("G/adk-test"), withDestinationPath: "../C/adk-test")
        try FileManager.default.createSymbolicLink(atPath: fx.path("C/adk-test"), withDestinationPath: "../bin/adk-test")
        guard case .failure(.unsafeOwnerOrMode(let d)) = ToolExecutableResolver().resolve(candidates: [fx.path("A/adk-test")], toolName: "adk-test") else {
            return XCTFail("accepted")
        }
        XCTAssertTrue(d.hasSuffix("/G"), d)
    }

    /// The docker alias is only for docker, and a com.docker.cli in a writable dir is still refused.
    func testDockerAliasCannotBeAbused() throws {
        let cli = try ToolFixtures.writeTool(in: fx, name: "com.docker.cli")
        guard case .success = ToolExecutableResolver().resolve(candidates: [cli], toolName: "docker") else { return XCTFail("alias not honoured") }
        guard case .failure(.nameMismatch) = ToolExecutableResolver().resolve(candidates: [cli], toolName: "adk-test") else {
            return XCTFail("alias leaked to another tool")
        }
        let w = try mkdir("W", 0o777)
        let planted = w + "/com.docker.cli"
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: URL(fileURLWithPath: planted)); chmod(planted, 0o755)
        let s = try mkdir("S")
        try FileManager.default.createSymbolicLink(atPath: s + "/docker", withDestinationPath: planted)
        guard case .failure(.unsafeOwnerOrMode) = ToolExecutableResolver().resolve(candidates: [s + "/docker"], toolName: "docker") else {
            return XCTFail("ran a com.docker.cli planted in a world-writable dir")
        }
    }

    func testRelativeCandidatesAreIgnored() {
        guard case .failure(.notFound) = ToolExecutableResolver().resolve(candidates: ["bin/adk-test", "./adk-test", "adk-test"], toolName: "adk-test")
        else { return XCTFail("relative candidate used") }
    }

    // MARK: Item 2 — identity

    /// [FAILS] In-place rewrite, same size, mtime restored with utimes: dev/ino/size/mtime all match. ctime would not.
    func testSameSizeRewriteWithForgedMtimeIsRefused() async throws {
        let exe = try ToolFixtures.writeTool(in: fx, body: "exit 0 #AAAA")
        let runner = FakeToolRunner()
        let p = performer(exe: exe, runner: runner)
        let (_, snap) = await p.planCheck(ToolFixtures.virtualItem(), probes: ToolProbeCache())
        var st = stat(); stat(exe, &st)
        let fd = open(exe, O_WRONLY)                                   // same inode
        _ = "#!/bin/sh\nexit 0 #EVIL\n".withCString { write(fd, $0, strlen($0)) }
        close(fd)
        var times = [st.st_atimespec, st.st_mtimespec]
        XCTAssertEqual(utimensat(AT_FDCWD, exe, &times, 0), 0)
        guard case .blocked(let b, _) = await p.execute(ToolFixtures.virtualItem(), expected: snap) else {
            return XCTFail("ran a binary rewritten in place with forged mtime (identity lacks ctime)")
        }
        XCTAssertEqual(b, [.identityChanged])
    }

    /// Replace-by-rename with the same size and forged mtime: new inode, refused.
    func testRenameSwapWithForgedSizeAndMtimeIsRefused() async throws {
        let exe = try ToolFixtures.writeTool(in: fx, body: "exit 0 #AAAA")
        let runner = FakeToolRunner()
        let p = performer(exe: exe, runner: runner)
        let (_, snap) = await p.planCheck(ToolFixtures.virtualItem(), probes: ToolProbeCache())
        var st = stat(); stat(exe, &st)
        let tmp = fx.path("bin/.swap")
        try Data("#!/bin/sh\nexit 0 #EVIL\n".utf8).write(to: URL(fileURLWithPath: tmp)); chmod(tmp, 0o755)
        var times = [st.st_atimespec, st.st_mtimespec]
        utimensat(AT_FDCWD, tmp, &times, 0)
        XCTAssertEqual(rename(tmp, exe), 0)
        guard case .blocked(let b, _) = await p.execute(ToolFixtures.virtualItem(), expected: snap) else { return XCTFail("ran") }
        XCTAssertEqual(b, [.identityChanged]); XCTAssertTrue(runner.calls.isEmpty)
    }

    /// Delete + recreate (inode reuse attempt) with forged size/mtime: still refused.
    func testUnlinkRecreateIsRefused() async throws {
        let exe = try ToolFixtures.writeTool(in: fx, body: "exit 0 #AAAA")
        let p = performer(exe: exe, runner: FakeToolRunner())
        let (_, snap) = await p.planCheck(ToolFixtures.virtualItem(), probes: ToolProbeCache())
        var st = stat(); stat(exe, &st)
        unlink(exe)
        try Data("#!/bin/sh\nexit 0 #EVIL\n".utf8).write(to: URL(fileURLWithPath: exe)); chmod(exe, 0o755)
        var times = [st.st_atimespec, st.st_mtimespec]
        utimensat(AT_FDCWD, exe, &times, 0)
        guard case .blocked = await p.execute(ToolFixtures.virtualItem(), expected: snap) else { return XCTFail("ran") }
    }

    /// A plan snapshot from before F10 (no identity) fails closed.
    func testLegacySnapshotWithoutIdentityFailsClosed() async throws {
        let exe = try ToolFixtures.writeTool(in: fx)
        let p = performer(exe: exe, runner: FakeToolRunner())
        let (_, snap) = await p.planCheck(ToolFixtures.virtualItem(), probes: ToolProbeCache())
        let s = try XCTUnwrap(snap)
        let legacy = ToolCommandSnapshot(specID: s.specID, executablePath: s.executablePath, argv: s.argv,
                                         environmentDisplay: s.environmentDisplay, targetLabel: s.targetLabel)
        guard case .blocked(let b, _) = await p.execute(ToolFixtures.virtualItem(), expected: legacy) else { return XCTFail("ran") }
        XCTAssertEqual(b, [.identityChanged])
    }

    // MARK: Item 3 — intent + history

    /// A real tool that SIGKILLs itself: the intent line is on disk.
    func testIntentSurvivesToolKilledBySignal() async throws {
        let exe = try ToolFixtures.writeTool(in: fx, body: "kill -9 $$")
        let url = URL(fileURLWithPath: fx.path("audit/audit.jsonl"))
        let p = performer(exe: exe, runner: ToolCommandRunner(), log: AuditLog(fileURL: url))
        let (_, snap) = await p.planCheck(ToolFixtures.virtualItem(), probes: ToolProbeCache())
        guard case .ran(.failed, _) = await p.execute(ToolFixtures.virtualItem(), expected: snap) else { return XCTFail("not failed") }
        XCTAssertEqual(try AuditLog.read(url).map(\.result), ["intent"])
    }

    private func rec(_ result: String, item: String = "a", at t: TimeInterval, run: UUID = UUID()) -> AuditRecord {
        AuditRecord(timestamp: Date(timeIntervalSince1970: t), runID: run, itemID: item, path: "/p", bytes: 5,
                    action: .deletePermanently, result: result, trashPath: nil, ruleID: "r", tool: "adktest", reasons: [],
                    error: nil, command: ["/x/adk-test", "rm", item])
    }
    private func history(_ recs: [AuditRecord]) throws -> AuditHistory {
        let enc = DiskKeeperJSON.makeEncoder(); var d = Data()
        for r in recs { d.append(try enc.encode(r)); d.append(0x0A) }
        return AuditHistoryReader.parse(d)
    }
    private func orphans(_ h: AuditHistory) -> Int { h.runs.flatMap(\.records).filter { $0.result == "intent" }.count }

    /// [FAILS] Crash on Monday (orphan intent), clean rerun on Tuesday: the Monday crash must stay visible.
    /// `settled` is never consumed, so one outcome hides every earlier intent of the same item+command.
    func testLaterSuccessfulRerunDoesNotHideEarlierCrash() throws {
        let h = try history([rec("intent", at: 1), rec("intent", at: 100), rec("ran", at: 101)])
        XCTAssertEqual(orphans(h), 1)
    }

    /// [FAILS] A later *skipped* outcome (blocked before any intent is written, but it carries `command`) settles an
    /// unrelated orphan intent.
    func testSkippedOutcomeDoesNotSettleAnIntent() throws {
        let h = try history([rec("intent", at: 1), rec("skipped", at: 50)])
        XCTAssertEqual(orphans(h), 1)
    }

    /// [FAILS] Two overlapping runs (two app instances / two engines) of the same item+command, one outcome: one orphan.
    func testConcurrentRunsSameItemOneOutcome() throws {
        let h = try history([rec("intent", at: 1), rec("intent", at: 2), rec("ran", at: 3)])
        XCTAssertEqual(orphans(h), 1)
    }

    /// Different items never settle each other; an orphan counts as nothing.
    func testOrphanIntentCountsAsNothing() throws {
        let h = try history([rec("intent", item: "a", at: 1), rec("ran", item: "b", at: 2)])
        XCTAssertEqual(orphans(h), 1)
        XCTAssertEqual(h.runs.reduce(0) { $0 + $1.items }, 1)
        XCTAssertEqual(h.lifetimeReclaimed, 0)
    }
}
