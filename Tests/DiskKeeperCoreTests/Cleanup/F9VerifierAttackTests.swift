import Darwin
import Foundation
import XCTest
@testable import DiskKeeperCore

/// PR #146 (F9) verifier attacks. Fixture home in a temp dir only; fake trash; fake tool runner.
final class F9VerifierAttackTests: CleanupTestCase {
    private let size = 1_500_000

    private struct Setup {
        var paths: [String]
        var group: DuplicateGroup
        var items: [ScanItem]
        var groups: [String: DuplicateGroup] { [group.id: group] }
    }

    private func makeGroup(_ names: [String]) async throws -> Setup {
        let content = DupFix.data(seed: 7, count: size)
        for (i, n) in names.enumerated() {
            let p = try DupFix.write(fx.path("home/docs/\(n)"), content)
            try DupFix.setBirthTime(p, Date(timeIntervalSinceNow: Double(-9000 + i * 100)))
        }
        let env = PathEnvironment(home: home, temporaryDirectory: fx.path("tmp"), variables: [:])
        let tree = try await DiskIndexer(environment: env, pathGuard: try makeGuard()).index(.home)
        var options = DuplicateOptions(environment: env)
        options.minimumLogicalBytes = 1_000_000
        let report = try await DuplicateFinder(options: options).find(in: tree)
        let group = try XCTUnwrap(report.groups.first)
        let items = group.members.map { DuplicateScanner.makeItem($0, group: group, keeper: group.keeper, rule: .oldest) }
        return Setup(paths: group.members.map(\.path), group: group, items: items)
    }

    private func nonDup(_ rel: String) throws -> ScanItem { try item(rel, rule: "r.other", tier: .review) }
    private func codes(_ plan: CleanupPlan, _ id: String) -> [String] {
        plan.entries.first { $0.item.id == id }?.blockers.map(\.code) ?? []
    }
    private func wasTrashed(_ r: CleanupReport, _ id: String) -> Bool {
        r.results.contains { if $0.itemID == id, case .trashed = $0.outcome { true } else { false } }
    }

    // MARK: #86

    /// Firmlink alias: a folder item named through /System/Volumes/Data still claims the survivor inside it.
    func testFirmlinkAliasFolderClaimsSurvivor() async throws {
        let s = try await makeGroup(["k/a", "b"])
        let real = String(cString: realpath(fx.path("home/docs/k"), nil))
        let alias = "/System/Volumes/Data" + real
        guard FileManager.default.fileExists(atPath: alias) else { throw XCTSkip("no data-volume alias here") }
        let url = URL(fileURLWithPath: alias)
        let r = try FileSizer().sizeBlocking(of: url)
        let aliased = ScanItem(url: url, displayName: "k", tool: .claudeCode, category: .buildArtifact,
                               sizeAllocated: r.allocatedBytes, sizeLogical: r.logicalBytes, fileCount: r.fileCount,
                               lastModified: r.newestModification, tier: .review, explanation: "test", ruleID: "r.other",
                               cleanupMethod: .trash)
        let engine = try makeEngine()
        let plan = await engine.plan([s.items[1], aliased], duplicateGroups: s.groups)
        XCTAssertTrue(codes(plan, s.items[1].id).contains("wouldRemoveAllCopies"), "\(codes(plan, s.items[1].id))")
        let report = try await engine.execute(plan)
        XCTAssertFalse(wasTrashed(report, s.items[1].id))
    }

    /// Swap at execute: the survivor's directory is moved into a folder item and replaced by a symlink to it.
    /// Lexically the survivor is unclaimed; physically it now lives inside the folder that will be trashed.
    func testSurvivorDirectorySwappedForSymlinkIntoClaimedFolder() async throws {
        let s = try await makeGroup(["k/a", "b"])
        try fx.file("home/docs/f/x", bytes: 10)
        let folder = try nonDup("home/docs/f")
        let engine = try makeEngine()
        let plan = await engine.plan([s.items[1], folder], duplicateGroups: s.groups)
        XCTAssertTrue(plan.entries.first { $0.item.id == s.items[1].id }!.isExecutable)
        try FileManager.default.moveItem(atPath: fx.path("home/docs/k"), toPath: fx.path("home/docs/f/k"))
        XCTAssertEqual(symlink(fx.path("home/docs/f"), fx.path("home/docs/k")), 0)
        let report = try await engine.execute(plan)
        XCTAssertFalse(wasTrashed(report, s.items[1].id), "dup trashed while its only survivor sits inside a trashed folder")
        let outside = [fx.path("home/docs/b"), fx.path("home/docs/f/k/a")].filter { FileManager.default.fileExists(atPath: $0) }
        XCTAssertFalse(outside.isEmpty, "no copy left outside the Trash")
    }

    /// Survivor replaced by a same-content copy (new inode, mtime restored): refused, nothing trashed.
    func testSurvivorReplacedByIdenticalCopyIsRefused() async throws {
        let s = try await makeGroup(["a", "b"])
        let engine = try makeEngine()
        let plan = await engine.plan([s.items[1]], duplicateGroups: s.groups)
        var st = stat(); XCTAssertEqual(lstat(s.paths[0], &st), 0)
        let tmp = fx.path("home/docs/.swap")
        try FileManager.default.copyItem(atPath: s.paths[0], toPath: tmp)
        var times = [st.st_atimespec, st.st_mtimespec]
        XCTAssertEqual(utimensat(AT_FDCWD, tmp, &times, 0), 0)
        XCTAssertEqual(rename(tmp, s.paths[0]), 0)
        let report = try await engine.execute(plan)
        XCTAssertEqual(skippedCodes(report.results[0].outcome), ["survivorChanged"])
        XCTAssertTrue(trashContents().isEmpty)
    }

    /// A hard link to the survivor, added as a normal item, claims it by inode (conservative: blocked).
    func testHardLinkOfSurvivorAsNormalItemIsClaimedByInode() async throws {
        let s = try await makeGroup(["a", "b"])
        XCTAssertEqual(link(s.paths[0], fx.path("home/other-hl")), 0)
        let hl = try nonDup("home/other-hl")
        let engine = try makeEngine()
        let plan = await engine.plan([s.items[1], hl], duplicateGroups: s.groups)
        XCTAssertTrue(codes(plan, s.items[1].id).contains("wouldRemoveAllCopies"), "\(codes(plan, s.items[1].id))")
        _ = try await engine.execute(plan)
        XCTAssertTrue(FileManager.default.fileExists(atPath: s.paths[0]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: s.paths[1]))
    }

    /// A survivor hard-linked into the plan only at execute time (after plan()) is caught by the execute-time inode claim.
    func testHardLinkCreatedAfterPlanIsClaimedAtExecute() async throws {
        let s = try await makeGroup(["a", "b"])
        try fx.file("home/other", bytes: 10)
        let other = try nonDup("home/other")
        let engine = try makeEngine()
        let plan = await engine.plan([s.items[1], other], duplicateGroups: s.groups)
        XCTAssertTrue(plan.entries.allSatisfy(\.isExecutable))
        // Replace the normal item with a hard link of the survivor: the item fingerprint changes too.
        XCTAssertEqual(unlink(fx.path("home/other")), 0)
        XCTAssertEqual(link(s.paths[0], fx.path("home/other")), 0)
        let report = try await engine.execute(plan)
        XCTAssertTrue(FileManager.default.fileExists(atPath: s.paths[0]) || FileManager.default.fileExists(atPath: s.paths[1]))
        XCTAssertFalse(wasTrashed(report, s.items[1].id) && wasTrashed(report, other.id))
    }

    // MARK: #42

    func testReplayExpiredTamperedAndForeignEngine() async throws {
        try fx.file("home/cache/a/f", bytes: 100)
        let clock = Clock()
        let e1 = try makeEngine(now: { clock.now() })
        let e2 = try makeEngine(now: { clock.now() })
        let plan = await e1.plan([try item("home/cache/a")])
        // Another engine never knew the plan.
        do { _ = try await e2.execute(plan); XCTFail("foreign engine ran it") } catch { XCTAssertEqual(error as? CleanupError, .unknownPlan) }
        // Expired, then replayed after the clock comes back: still refused (monotonic clock).
        clock.advance(3600)
        do { _ = try await e1.execute(plan); XCTFail("expired ran") } catch { XCTAssertEqual(error as? CleanupError, .planExpired) }
        // A pre-slot expiry does not burn the id: with the wall clock back and the monotonic age still tiny, the
        // plan is genuinely within its lifetime and runs once; any replay after that is refused.
        clock.advance(-3600)
        _ = try await e1.execute(plan)
        do { _ = try await e1.execute(plan); XCTFail("replayed") } catch { XCTAssertEqual(error as? CleanupError, .planAlreadyExecuted) }
        do { _ = try await e2.execute(plan); XCTFail("foreign replay") } catch { XCTAssertEqual(error as? CleanupError, .unknownPlan) }
    }

    /// Expired while queued burns the id: a later replay is planAlreadyExecuted, never a run.
    func testExpiredWhileQueuedIsBurned() async throws {
        try fx.file("home/cache/a/f", bytes: 100); try fx.file("home/cache/b/f", bytes: 100)
        let clock = Clock()
        let (engine, fifo) = try makeFIFOEngine(clock: clock)   // deterministic ordering (was an `async let` race)
        let first = await engine.plan([try item("home/cache/a")])
        let second = await engine.plan([try item("home/cache/b")])
        let e = try await executeExpiringWhileQueued(engine, fifo: fifo, clock: clock, first: first, second: second)
        XCTAssertEqual(e as? CleanupError, .planExpired)
        clock.advance(-20 * 60)
        do { _ = try await engine.execute(second); XCTFail("burned plan ran") } catch {
            XCTAssertEqual(error as? CleanupError, .planAlreadyExecuted)
        }
        XCTAssertTrue(exists("home/cache/b/f"))
    }

    // MARK: N2 / N3 / pairing

    private func performer(exe: String, intentLog: AuditLog?, runner: FakeToolRunner) -> ToolCommandPerformer {
        let env = PathEnvironment(home: home, temporaryDirectory: fx.path("tmp"), variables: [:])
        return ToolCommandPerformer(registry: ToolCommandRegistry(specs: [ToolFixtures.spec(exe: exe)]),
                                    context: ToolCommandContext(environment: env, runner: runner), intentLog: intentLog)
    }

    /// Timing seam: the intent log is a FIFO, so `open()` blocks until a reader shows up. The executable is
    /// swapped while the intent write is in flight; the post-write re-stat must refuse to spawn.
    func testExecutableSwappedDuringIntentWriteIsNotRun() async throws {
        for swap in [true, false] {
            fx = try TemporaryDirectory(); try fx.dir("home"); try fx.dir("tmp"); try fx.dir("Trash")
            let runner = FakeToolRunner()
            let exe = try ToolFixtures.writeTool(in: fx)
            try fx.dir("audit")
            let fifo = fx.path("audit/intent.fifo")
            XCTAssertEqual(mkfifo(fifo, 0o600), 0)
            let p = performer(exe: exe, intentLog: AuditLog(fileURL: URL(fileURLWithPath: fifo)), runner: runner)
            let (_, snap) = await p.planCheck(ToolFixtures.virtualItem(), probes: ToolProbeCache())
            let captured = UnsafeSendableBox()
            let exePath = exe
            let reader = Thread {
                usleep(300_000)
                if swap {
                    let tmp = exePath + ".new"
                    FileManager.default.createFile(atPath: tmp, contents: Data("#!/bin/sh\necho evil; exit 0\n".utf8))
                    chmod(tmp, 0o755)
                    rename(tmp, exePath)
                }
                let fd = Darwin.open(fifo, O_RDONLY)
                var buf = [UInt8](repeating: 0, count: 65536)
                while true { let n = read(fd, &buf, buf.count); if n <= 0 { break }; captured.data.append(contentsOf: buf[0..<n]) }
                Darwin.close(fd)
            }
            reader.start()
            let run = await p.execute(ToolFixtures.virtualItem(), expected: snap)
            while !reader.isFinished { try await Task.sleep(nanoseconds: 20_000_000) }
            let intent = try DiskKeeperJSON.makeDecoder().decode(AuditRecord.self, from: Data(captured.data.split(separator: 0x0A)[0]))
            XCTAssertEqual(intent.result, AuditRecord.intentResult)
            if swap {
                guard case .blocked(let b, let rec) = run else { return XCTFail("spawned after a swap during the intent write") }
                XCTAssertEqual(b, [.identityChanged])
                XCTAssertEqual(rec.intentID, intent.intentID, "the not-run outcome must settle its intent")
                XCTAssertTrue(runner.calls.isEmpty)
            } else {
                guard case .ran(.ranCommand, let rec) = run else { return XCTFail("control did not run: \(run)") }
                XCTAssertEqual(rec.intentID, intent.intentID)
                XCTAssertEqual(runner.calls.count, 1)
            }
        }
    }

    /// N3 end to end: unwritable intent log → item outcome `.skipped([auditIntentNotWritten])`, no spawn, outcome line
    /// written to the main log as `skipped` with no intentID.
    func testUnwritableIntentThroughEngineIsSkippedNotFailed() async throws {
        let runner = FakeToolRunner()
        let exe = try ToolFixtures.writeTool(in: fx)
        try Data("x".utf8).write(to: URL(fileURLWithPath: fx.path("notadir")))
        let p = performer(exe: exe, intentLog: AuditLog(fileURL: URL(fileURLWithPath: fx.path("notadir/i.jsonl"))), runner: runner)
        let engine = CleanupEngine(pathGuard: try makeGuard(), auditLog: AuditLog(fileURL: auditURL),
                                   trash: DirectoryTrash(root: trashDir), runningApps: FakeRunningApps(), toolCommands: p)
        let plan = await engine.plan([ToolFixtures.virtualItem()])
        let report = try await engine.execute(plan)
        XCTAssertEqual(skippedCodes(report.results[0].outcome), ["auditIntentNotWritten"])
        XCTAssertTrue(runner.calls.isEmpty)
        let lines = try AuditLog.read(auditURL)
        XCTAssertEqual(lines.map(\.result), ["skipped"])
        XCTAssertNil(lines[0].intentID)
    }

    /// Exact pairing through the real engine: intent and outcome share the id, twice, on one log; history shows no
    /// dangling intent. A legacy (id-less) outcome never settles an id-carrying intent.
    func testEngineWritesPairedIntentIDs() async throws {
        let runner = FakeToolRunner()
        let exe = try ToolFixtures.writeTool(in: fx)
        let p = performer(exe: exe, intentLog: AuditLog(fileURL: auditURL), runner: runner)
        let engine = CleanupEngine(pathGuard: try makeGuard(), auditLog: AuditLog(fileURL: auditURL),
                                   trash: DirectoryTrash(root: trashDir), runningApps: FakeRunningApps(), toolCommands: p)
        for _ in 0..<2 { _ = try await engine.execute(await engine.plan([ToolFixtures.virtualItem()])) }
        let lines = try AuditLog.read(auditURL)
        XCTAssertEqual(lines.map(\.result), ["intent", "ran", "intent", "ran"])
        XCTAssertNotNil(lines[0].intentID)
        XCTAssertEqual(lines[0].intentID, lines[1].intentID)
        XCTAssertEqual(lines[2].intentID, lines[3].intentID)
        XCTAssertNotEqual(lines[0].intentID, lines[2].intentID)
        let data = try Data(contentsOf: auditURL)
        XCTAssertFalse(AuditHistoryReader.parse(data).runs.flatMap(\.records).contains { $0.result == AuditRecord.intentResult })

        // Interleaved (two writers): I1, I2, legacy outcome (no id) → only legacy intents may be settled by it.
        let enc = DiskKeeperJSON.makeEncoder()
        func rec(_ r: String, _ id: UUID?, _ t: TimeInterval) -> AuditRecord {
            AuditRecord(timestamp: Date(timeIntervalSince1970: t), runID: UUID(), itemID: "a", path: "/p", bytes: 5,
                        action: .deletePermanently, result: r, trashPath: nil, ruleID: "r", tool: "adktest", reasons: [],
                        error: nil, command: ["/x", "rm"], intentID: id)
        }
        var mixed = Data()
        for r in [rec("intent", UUID(), 1), rec("intent", UUID(), 2), rec("ran", nil, 3)] {
            mixed.append(try enc.encode(r)); mixed.append(0x0A)
        }
        let left = AuditHistoryReader.parse(mixed).runs.flatMap(\.records).filter { $0.result == "intent" }
        XCTAssertEqual(left.count, 2, "an id-less outcome settled an id-carrying intent")
    }
}

private final class UnsafeSendableBox: @unchecked Sendable { var data: [UInt8] = [] }
