import Darwin
import Foundation
import Testing
@testable import DiskKeeperCore

// Verifier attack tests for PR #153 (H5), adopted; the probes became assertions once the findings were fixed. Fake table + fake signaler, except the one live test at the bottom, which
// signals ONLY a child it spawned itself (tracked pid), and reaps it with SIGKILL in test code.
// Drop into Tests/DiskKeeperCoreTests/Process/ (reuses PCFakeTable / PCFakeSignaler / PCClock / PCAuditSink).

private let me = getuid()
private let ownPID: pid_t = 5000

private func rec(_ pid: pid_t, _ ppid: pid_t = 100, name: String = "worker", path: String? = "/Users/x/bin/worker",
                 start: UInt64? = nil, uid: uid_t = me, status: UInt32 = 2) -> ProcessRecord {
    ProcessRecord(pid: pid, ppid: ppid, uid: uid, name: name, executablePath: path, startID: start ?? UInt64(pid) * 10, status: status)
}
private func tgt(_ r: ProcessRecord) -> ProcessTarget { ProcessTarget(pid: r.pid, startID: r.startID, name: r.name) }

/// A table that runs a hook before answering snapshot #n (1-based), to model races.
final class RacyTable: ProcessTableReading, @unchecked Sendable {
    private let lock = NSLock()
    var records: [ProcessRecord]
    private var calls = 0
    private let hooks: [Int: ([ProcessRecord]) -> [ProcessRecord]]
    init(_ r: [ProcessRecord], hooks: [Int: ([ProcessRecord]) -> [ProcessRecord]]) { records = r; self.hooks = hooks }
    func snapshot() -> ProcessTableSnapshot? {
        lock.withLock {
            calls += 1
            if let h = hooks[calls] { records = h(records) }
            return ProcessTableSnapshot(at: .now, wall: Date(), records: records)
        }
    }
}

private let base = [rec(100, 1, name: "zsh", path: "/bin/zsh"),
                    rec(ownPID, 100, name: "AIDiskKeeper", path: "/Applications/AIDiskKeeper.app/Contents/MacOS/AIDiskKeeper")]

private func controller(_ table: any ProcessTableReading, _ sig: PCFakeSignaler, store: URL, clock: PCClock = PCClock(),
                        sink: PCAuditSink = PCAuditSink(), gui: Set<pid_t> = [], extra: Set<pid_t> = []) -> ProcessController {
    ProcessController(table: table, signaler: sig, store: PausedProcessStore(fileURL: store), isGUIApp: { gui.contains($0) },
                      ownPID: ownPID, ownUID: me, extraAncestors: { extra }, now: { clock.now }, autoResumeMinutes: 15, audit: { sink.add($0) })
}

@Suite struct H5AttackPidReuse {
    @Test func reuseBetweenPlanAndConfirmSendsNothing() async throws {
        let dir = try TemporaryDirectory()
        // snapshot 1 = plan; snapshot 2 = execute guard: pid 300 now belongs to a different process.
        let t = RacyTable(base + [rec(300)], hooks: [2: { $0.filter { $0.pid != 300 } + [rec(300, start: 999_999)] }])
        let s = PCFakeSignaler()
        let c = controller(t, s, store: dir.url.appendingPathComponent("p.json"))
        let plan = await c.plan([tgt(rec(300))], includeDescendants: false, action: .pause)
        let r = await c.execute(plan)
        #expect(r.map(\.outcome) == [.refused(.identityChanged)])
        #expect(s.calls.isEmpty)
        #expect(await c.state().paused.isEmpty)
    }

    @Test func reuseOfAChildMidTreeSkipsOnlyThatChild() async throws {
        let dir = try TemporaryDirectory()
        // plan=1, guard for 300 = 2, guard for 301 = 3 -> 301 replaced just before its own guard.
        let t = RacyTable(base + [rec(300), rec(301, 300), rec(302, 300)],
                          hooks: [3: { $0.filter { $0.pid != 301 } + [rec(301, 300, start: 7)] }])
        let s = PCFakeSignaler()
        let c = controller(t, s, store: dir.url.appendingPathComponent("p.json"))
        let r = await c.execute(await c.plan([tgt(rec(300))], includeDescendants: true, action: .pause))
        #expect(r.map(\.target.pid) == [300, 301, 302])
        #expect(r[1].outcome == .refused(.identityChanged))
        #expect(s.calls.map(\.pid) == [300, 302])
        #expect(s.calls.allSatisfy { $0.value == SIGSTOP })
    }

    @Test func pausedEntryWhosePidWasReusedIsNeverContinued() async throws {
        let dir = try TemporaryDirectory()
        let clock = PCClock()
        let t = PCFakeTable(base + [rec(300)])
        let s = PCFakeSignaler()
        let c = controller(t, s, store: dir.url.appendingPathComponent("p.json"), clock: clock)
        _ = await c.execute(await c.plan([tgt(rec(300))], includeDescendants: false, action: .pause))
        t.records = base + [rec(300, start: 4242)]   // original died, pid reused
        clock.advance(16 * 60)
        let r = await c.resumeDue()
        #expect(r.map(\.outcome) == [.refused(.identityChanged)])
        #expect(s.calls.filter { $0.value == SIGCONT }.isEmpty)
        #expect(await c.state().paused.isEmpty)
    }
}

@Suite struct H5AttackPausedJSON {
    private func write(_ url: URL, _ json: String) throws { try Data(json.utf8).write(to: url) }
    private func entry(_ pid: Int, _ start: UInt64) -> String {
        #"{"pid":\#(pid),"startID":\#(start),"name":"x","pausedAt":"2026-01-01T00:00:00Z","resumeAt":"2026-01-01T00:15:00Z"}"#
    }

    @Test func garbageAndFutureSchemaReadAsEmpty() throws {
        let dir = try TemporaryDirectory()
        let u = dir.url.appendingPathComponent("p.json")
        for j in ["not json", "{}", #"{"schemaVersion":2,"paused":[\#(entry(300, 3000))]}"#, #"{"schemaVersion":1,"paused":[{"pid":"x"}]}"#] {
            try write(u, j)
            #expect(PausedProcessStore(fileURL: u).load().isEmpty, "\(j)")
        }
    }

    @Test func tamperedEntriesNeverReachKill() async throws {
        // pid -1 (broadcast), 0 (group), 1 (launchd), a reused pid, a running (not stopped) process.
        let dir = try TemporaryDirectory()
        let u = dir.url.appendingPathComponent("p.json")
        try write(u, #"{"schemaVersion":1,"paused":[\#(entry(-1, 0)),\#(entry(0, 0)),\#(entry(1, 10)),\#(entry(300, 1)),\#(entry(301, 3010))]}"#)
        let t = PCFakeTable(base + [rec(1, 0, name: "launchd", path: "/sbin/launchd", uid: 0, status: 4),
                                    rec(300, status: 4), rec(301, status: 2)])
        let s = PCFakeSignaler()
        let c = controller(t, s, store: u)
        #expect(await c.recoveryCandidates().isEmpty)
        _ = await c.resumeAll()
        #expect(s.calls.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: u.path))   // emptied -> removed
    }

    /// A foreign-uid entry that IS stopped with a matching startID is not offered and is dropped at launch.
    @Test func foreignOwnerEntryIsDroppedAtLaunch() async throws {
        let dir = try TemporaryDirectory()
        let u = dir.url.appendingPathComponent("p.json")
        try write(u, #"{"schemaVersion":1,"paused":[\#(entry(300, 3000))]}"#)
        let t = PCFakeTable(base + [rec(300, uid: me &+ 1, status: 4)])
        let s = PCFakeSignaler(), sink = PCAuditSink()
        let c = controller(t, s, store: u, sink: sink)
        let offered = await c.recoveryCandidates()
        _ = await c.resumeDue(); _ = await c.resumeDue(); _ = await c.resumeDue()
        #expect(s.calls.isEmpty)   // safety holds: never signalled
        #expect(offered.isEmpty)
        #expect(await c.state().paused.isEmpty)
        #expect(sink.lines.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: u.path))
    }

    @Test func symlinkedStoreIsNotWrittenThrough() async throws {
        let dir = try TemporaryDirectory()
        let victim = dir.url.appendingPathComponent("victim.txt")
        try Data("keep".utf8).write(to: victim)
        let u = dir.url.appendingPathComponent("p.json")
        try FileManager.default.createSymbolicLink(at: u, withDestinationURL: victim)
        try PausedProcessStore(fileURL: u).save([PausedProcess(pid: 300, startID: 3000, name: "x", pausedAt: Date(), resumeAt: Date())])
        #expect(String(decoding: try Data(contentsOf: victim), as: UTF8.self) == "keep")
        let mode = try FileManager.default.attributesOfItem(atPath: u.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }
}

@Suite struct H5AttackAncestors {
    @Test func ownParentAndGrandparentAreRefusedForEveryAction() async throws {
        let dir = try TemporaryDirectory()
        // tmux(90) -> zsh(100) -> app(5000); all user paths so only the ancestor rule can refuse.
        let t = PCFakeTable([rec(90, 1, name: "tmux", path: "/opt/homebrew/bin/tmux"), rec(100, 90, name: "zsh", path: "/opt/homebrew/bin/zsh"),
                             rec(ownPID, 100, name: "AIDiskKeeper", path: "/Applications/A.app/A")])
        let s = PCFakeSignaler()
        let c = controller(t, s, store: dir.url.appendingPathComponent("p.json"))
        for a in [ProcessAction.pause, .background] {
            let p = await c.plan([tgt(rec(90, 1, name: "tmux")), tgt(rec(100, 90, name: "zsh"))], includeDescendants: true, action: a)
            #expect(p.actionable.isEmpty, "\(a)")
            _ = await c.execute(p)
        }
        #expect(s.calls.isEmpty)
    }

    /// The table is own-uid only, so an own-uid ancestor ABOVE a root-owned hop (e.g. /usr/bin/login) is invisible to it;
    /// the live ancestor chain (`extraAncestors`) covers it.
    @Test func ancestorAboveARootHopIsRefused() async throws {
        let dir = try TemporaryDirectory()
        let t = PCFakeTable([rec(80, 1, name: "ptyhost", path: "/Applications/Term.app/ptyhost"),
                             // 90 = login (root) is invisible to an own-uid table
                             rec(100, 90, name: "zsh", path: "/opt/homebrew/bin/zsh"),
                             rec(ownPID, 100, name: "AIDiskKeeper", path: "/Applications/A.app/A")])
        let blind = controller(t, PCFakeSignaler(), store: dir.url.appendingPathComponent("p.json"))
        #expect(await blind.plan([tgt(rec(80, 1, name: "ptyhost"))], includeDescendants: false, action: .pause)
            .rows.first?.refusal == nil, "documents why the live chain is needed")
        let c = controller(t, PCFakeSignaler(), store: dir.url.appendingPathComponent("p.json"), extra: [80, 90])
        let p = await c.plan([tgt(rec(80, 1, name: "ptyhost"))], includeDescendants: false, action: .pause)
        #expect(p.rows.first?.refusal == .ownProcessOrAncestor)
    }

    @Test func liveAncestorsContainTheRealParent() {
        #expect(ProcessControlPolicy.liveAncestors().contains(getppid()))
        #expect(!ProcessControlPolicy.liveAncestors().contains(getpid()))
    }
}

@Suite struct H5AttackChildExit {
    @Test func childGoneBetweenListAndSignal() async throws {
        let dir = try TemporaryDirectory()
        let t = RacyTable(base + [rec(300), rec(301, 300)], hooks: [3: { $0.filter { $0.pid != 301 } }])
        let s = PCFakeSignaler()
        let c = controller(t, s, store: dir.url.appendingPathComponent("p.json"))
        let r = await c.execute(await c.plan([tgt(rec(300))], includeDescendants: true, action: .pause))
        #expect(r.map(\.outcome) == [.done, .refused(.vanished)])
        #expect(s.calls.map(\.pid) == [300])
        #expect(await c.state().paused.map(\.pid) == [300])
    }

    @Test func childExitsAfterGuardESRCHRollsBackPausedEntry() async throws {
        let dir = try TemporaryDirectory()
        let u = dir.url.appendingPathComponent("p.json")
        let t = PCFakeTable(base + [rec(300)])
        let s = PCFakeSignaler(); s.failWith = ESRCH
        let c = controller(t, s, store: u)
        let r = await c.execute(await c.plan([tgt(rec(300))], includeDescendants: false, action: .pause))
        #expect(r.map(\.outcome) == [.failed(errno: ESRCH)])
        #expect(await c.state().paused.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: u.path))
    }

    /// "Include child processes" OFF + "Keep new children in background" ON: existing children the user excluded are
    /// never touched; only processes that appear later.
    @Test func keepChildrenLeavesExcludedExistingChildrenAlone() async throws {
        let dir = try TemporaryDirectory()
        let t = PCFakeTable(base + [rec(300), rec(301, 300)])
        let s = PCFakeSignaler()
        let c = controller(t, s, store: dir.url.appendingPathComponent("p.json"))
        _ = await c.execute(await c.plan([tgt(rec(300))], includeDescendants: false, action: .background))
        await c.setKeepChildrenInBackground([tgt(rec(300))], on: true)
        _ = await c.tickKeepChildren()
        #expect(s.calls.filter { $0.kind == "bg" }.map(\.pid) == [300])
        t.records = base + [rec(300), rec(301, 300), rec(302, 300)]
        _ = await c.tickKeepChildren()
        #expect(s.calls.filter { $0.kind == "bg" }.map(\.pid) == [300, 302])
    }

    /// A resume that fails (e.g. EPERM) is attempted and audited once, then the entry is dropped: no retry loop.
    @Test func persistentResumeFailureIsAuditedOnce() async throws {
        let dir = try TemporaryDirectory()
        let clock = PCClock()
        let t = PCFakeTable(base + [rec(300)])
        let s = PCFakeSignaler(), sink = PCAuditSink()
        let c = controller(t, s, store: dir.url.appendingPathComponent("p.json"), clock: clock, sink: sink)
        _ = await c.execute(await c.plan([tgt(rec(300))], includeDescendants: false, action: .pause))
        s.failWith = EPERM
        clock.advance(16 * 60)
        for _ in 0..<10 { _ = await c.resumeDue() }
        #expect(await c.state().paused.isEmpty)
        #expect(sink.lines.filter { $0.action == "resume" }.count == 1)
        #expect(s.calls.filter { $0.value == SIGCONT }.count == 1)
    }
}

/// Live: BG inheritance across fork/exec. Spawns its OWN bash child, which forks a sleep AFTER we background bash.
/// Only the tracked pids are touched; both are SIGKILLed in test code.
/// PROC_FLAG_DARWINBG (0x10000) in pbi_flags; getpriority(PRIO_DARWIN_PROCESS) reads 0 for another process.
private func darwinBG(_ pid: pid_t) -> Bool {
    var b = proc_bsdinfo()
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &b, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 else { return false }
    return b.pbi_flags & 0x10000 != 0
}

@Suite(.serialized) struct H5LiveInheritance {
    @Test func doesBackgroundInheritToNewChildren() async throws {
        let dir = try TemporaryDirectory()
        let flag = dir.url.appendingPathComponent("go").path
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", "while [ ! -e '\(flag)' ]; do /bin/sleep 0.05; done; /bin/sleep 30 & echo $! > '\(flag).pid'; wait"]
        try p.run()
        let bash = p.processIdentifier
        defer { kill(bash, SIGKILL); p.waitUntilExit() }
        let sig = LiveProcessSignaling()
        #expect(sig.setBackground(bash, true) == 0)
        let bashPrio = darwinBG(bash)
        FileManager.default.createFile(atPath: flag, contents: nil)
        var child: pid_t = 0
        for _ in 0..<100 {
            if let s = try? String(contentsOfFile: flag + ".pid", encoding: .utf8),
               let v = Int32(s.trimmingCharacters(in: .whitespacesAndNewlines)) { child = v; break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(child > 1)
        defer { if child > 1 { kill(child, SIGKILL) } }
        try await Task.sleep(for: .milliseconds(100))
        let childPrio = darwinBG(child)
        #expect(bashPrio, "the pid we backgrounded shows the Darwin BG flag")
        #expect(childPrio, "a child forked and exec'd afterwards inherits it (docs/process-control.md)")
    }
}
