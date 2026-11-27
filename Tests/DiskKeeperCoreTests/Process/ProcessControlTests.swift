import Darwin
import Foundation
import Testing
@testable import DiskKeeperCore

// Everything here runs against a fake table and a fake signaler: no real process is ever signalled.

final class FakeTable: ProcessTableReading, @unchecked Sendable {
    private let lock = NSLock()
    private var _records: [ProcessRecord]
    init(_ records: [ProcessRecord]) { _records = records }
    var records: [ProcessRecord] {
        get { lock.withLock { _records } }
        set { lock.withLock { _records = newValue } }
    }
    func snapshot() -> ProcessTableSnapshot? { ProcessTableSnapshot(at: .now, wall: Date(), records: records) }
}

final class FakeSignaler: ProcessSignaling, @unchecked Sendable {
    struct Call: Equatable { let kind: String; let pid: pid_t; let value: Int32 }
    private let lock = NSLock()
    private var _calls: [Call] = []
    var failWith: Int32 = 0
    var calls: [Call] { lock.withLock { _calls } }
    func setBackground(_ pid: pid_t, _ on: Bool) -> Int32 { lock.withLock { _calls.append(Call(kind: "bg", pid: pid, value: on ? 1 : 0)) }; return failWith }
    func signal(_ pid: pid_t, _ sig: Int32) -> Int32 { lock.withLock { _calls.append(Call(kind: "sig", pid: pid, value: sig)) }; return failWith }
}

final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var t = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date { lock.withLock { t } }
    func advance(_ s: TimeInterval) { lock.withLock { t = t.addingTimeInterval(s) } }
}

final class AuditSink: @unchecked Sendable {
    private let lock = NSLock()
    private var _lines: [ProcessControlAuditRecord] = []
    var lines: [ProcessControlAuditRecord] { lock.withLock { _lines } }
    func add(_ r: ProcessControlAuditRecord) { lock.withLock { _lines.append(r) } }
}

private let me = getuid()
private let ownPID: pid_t = 5000

private func rec(_ pid: pid_t, _ ppid: pid_t = 100, name: String = "worker", path: String? = "/Users/x/bin/worker", start: UInt64? = nil,
                 uid: uid_t = me, status: UInt32 = 2) -> ProcessRecord {
    ProcessRecord(pid: pid, ppid: ppid, uid: uid, name: name, executablePath: path, startID: start ?? UInt64(pid) * 10, status: status)
}

private func target(_ r: ProcessRecord) -> ProcessTarget { ProcessTarget(pid: r.pid, startID: r.startID, name: r.name) }

private struct Rig {
    let table: FakeTable, signaler = FakeSignaler(), clock = Clock(), sink = AuditSink(), dir: TemporaryDirectory
    let controller: ProcessController
    var storeURL: URL { dir.url.appendingPathComponent("paused.json") }

    init(_ records: [ProcessRecord], gui: Set<pid_t> = [], minutes: Int = 15) throws {
        dir = try TemporaryDirectory()
        table = FakeTable(records)
        let s = signaler, c = clock, k = sink
        controller = ProcessController(
            table: table, signaler: s, store: PausedProcessStore(fileURL: dir.url.appendingPathComponent("paused.json")),
            isGUIApp: { gui.contains($0) }, ownPID: ownPID, ownUID: me, now: { c.now }, autoResumeMinutes: minutes,
            audit: { k.add($0) })
    }
}

/// App (5000) <- launchd (1); user processes hang off 100.
private let base = [rec(1, 0, name: "launchd", path: "/sbin/launchd", uid: 0), rec(100, 1, name: "zsh", path: "/bin/zsh"),
                    rec(ownPID, 100, name: "AIDiskKeeper", path: "/Applications/AIDiskKeeper.app/Contents/MacOS/AIDiskKeeper")]

@Suite struct ProcessControlPolicyTests {
    private func refusal(_ r: ProcessRecord, _ a: ProcessAction, gui: Bool = false, ancestors: Set<pid_t> = [100]) -> ProcessRefusal? {
        ProcessControlPolicy.refusal(r, action: a, ownPID: ownPID, ownAncestors: ancestors, isGUIApp: gui, ownUID: me)
    }

    @Test func allowsAnOrdinaryOwnProcess() {
        for a in [ProcessAction.background, .pause, .resume, .restorePriority] { #expect(refusal(rec(200), a) == nil) }
    }
    @Test func otherUserAndLaunchd() {
        #expect(refusal(rec(200, uid: me &+ 1), .pause) == .otherUser)
        #expect(refusal(rec(1), .pause) == .launchd)
        #expect(refusal(rec(0), .background) == .launchd)
    }
    @Test func ownProcessAndAncestors() {
        #expect(refusal(rec(ownPID), .pause) == .ownProcessOrAncestor)
        #expect(refusal(rec(100), .background) == .ownProcessOrAncestor)
    }
    @Test func systemPaths() {
        for p in ["/System/Library/x", "/usr/bin/ssh", "/usr/libexec/y", "/sbin/z", "/bin/ls", "/Library/Apple/System/q"] {
            #expect(refusal(rec(200, path: p), .pause) == .systemProcess, "\(p)")
        }
        #expect(refusal(rec(200, path: "/usr/local/bin/node"), .pause) == nil)
        #expect(refusal(rec(200, path: "/opt/homebrew/bin/node"), .pause) == nil)
    }
    @Test func unreadablePathIsRefused() { #expect(refusal(rec(200, path: nil), .pause) == .unreadablePath) }
    @Test func denylist() {
        for n in ["WindowServer", "loginwindow", "Finder", "Dock", "SystemUIServer", "ControlCenter", "coreaudiod", "launchservicesd"] {
            #expect(refusal(rec(200, name: n), .pause) == .denylisted(n))
            #expect(refusal(rec(200, name: n), .background) == .denylisted(n))
        }
    }
    @Test func guiAppCanBeBackgroundedButNotPaused() {
        #expect(refusal(rec(200), .pause, gui: true) == .guiAppPause)
        #expect(refusal(rec(200), .background, gui: true) == nil)
    }
    @Test func resumeIsNeverBlockedByPolicyChanges() {
        // Something we paused must always be resumable: only another user's process or pid <= 1 are refused.
        #expect(refusal(rec(200, name: "Finder", path: "/System/Library/CoreServices/Finder.app/x"), .resume, gui: true) == nil)
        #expect(refusal(rec(200, uid: me &+ 1), .resume) == .otherUser)
    }
}

@Suite struct ProcessTreeOrderTests {
    // 200 -> 201 -> 203 ; 200 -> 202
    private let tree = base + [rec(200), rec(201, 200), rec(202, 200), rec(203, 201)]

    @Test func pauseParentFirstThenChildrenBFS() throws {
        let rig = try Rig(tree)
        let plan = rig.controller.plan([target(rec(200))], includeDescendants: true, action: .pause)
        #expect(plan.rows.map(\.target.pid) == [200, 201, 202, 203])
        #expect(plan.rows.first?.isRoot == true)
    }
    @Test func resumeChildrenFirst() async throws {
        let rig = try Rig(tree)
        let plan = await rig.controller.plan([target(rec(200))], includeDescendants: true, action: .resume)
        #expect(plan.rows.map(\.target.pid) == [203, 202, 201, 200])
    }
    @Test func cycleSafe() async throws {
        let cyc = base + [rec(200, 201), rec(201, 200)]
        let rig = try Rig(cyc)
        let plan = await rig.controller.plan([target(rec(200, 201))], includeDescendants: true, action: .pause)
        #expect(plan.rows.map(\.target.pid) == [200, 201])
    }
    @Test func policyIsEvaluatedPerMember() async throws {
        let mixed = base + [rec(200), rec(201, 200, name: "Finder"), rec(202, 200, path: "/usr/bin/ssh"), rec(203, 200)]
        let rig = try Rig(mixed, gui: [203])
        let plan = await rig.controller.plan([target(rec(200))], includeDescendants: true, action: .pause)
        let by = Dictionary(uniqueKeysWithValues: plan.rows.map { ($0.target.pid, $0.refusal) })
        #expect(by[200] == .some(nil))
        #expect(by[201] == .denylisted("Finder"))
        #expect(by[202] == .systemProcess)
        #expect(by[203] == .guiAppPause)
        let results = await rig.controller.execute(plan)
        #expect(rig.signaler.calls.map(\.pid) == [200], "only the allowed member is signalled")
        #expect(results.count == 4)
    }
    @Test func pauseSendsOnlySIGSTOPAndResumeOnlySIGCONT() async throws {
        let rig = try Rig(tree)
        _ = await rig.controller.execute(await rig.controller.plan([target(rec(200))], includeDescendants: true, action: .pause))
        #expect(rig.signaler.calls.allSatisfy { $0.kind == "sig" && $0.value == SIGSTOP })
        _ = await rig.controller.resumeAll()
        let conts = rig.signaler.calls.filter { $0.value == SIGCONT }
        #expect(rig.signaler.calls.allSatisfy { $0.kind == "sig" && ($0.value == SIGSTOP || $0.value == SIGCONT) })
        #expect(conts.first?.pid == 203, "deepest first")
        #expect(conts.last?.pid == 200)
    }
}

@Suite struct IdentityGuardTests {
    @Test func reusedPidIsNotSignalled() async throws {
        let rig = try Rig(base + [rec(200)])
        let plan = await rig.controller.plan([target(rec(200))], includeDescendants: false, action: .pause)
        rig.table.records = base + [rec(200, start: 99_999)]   // same pid, new process
        let results = await rig.controller.execute(plan)
        #expect(results.first?.outcome == .refused(.identityChanged))
        #expect(rig.signaler.calls.isEmpty)
    }
    @Test func planWithStaleTargetIsRefused() async throws {
        let rig = try Rig(base + [rec(200, start: 77)])
        let plan = await rig.controller.plan([target(rec(200))], includeDescendants: false, action: .background)
        #expect(plan.rows.first?.refusal == .identityChanged)
        #expect(await rig.controller.execute(plan).first?.outcome == .refused(.identityChanged))
        #expect(rig.signaler.calls.isEmpty)
    }
    @Test func vanishedProcessIsNotSignalled() async throws {
        let rig = try Rig(base + [rec(200)])
        let plan = await rig.controller.plan([target(rec(200))], includeDescendants: false, action: .pause)
        rig.table.records = base
        #expect(await rig.controller.execute(plan).first?.outcome == .refused(.vanished))
        #expect(rig.signaler.calls.isEmpty)
    }
    @Test func failedSignalLeavesNothingPaused() async throws {
        let rig = try Rig(base + [rec(200)])
        rig.signaler.failWith = EPERM
        let r = await rig.controller.execute(await rig.controller.plan([target(rec(200))], includeDescendants: false, action: .pause))
        #expect(r.first?.outcome == .failed(errno: EPERM))
        #expect(await rig.controller.state().paused.isEmpty)
        #expect(PausedProcessStore(fileURL: rig.storeURL).load().isEmpty)
    }
    @Test func everyProcessGetsOneAuditLine() async throws {
        let rig = try Rig(base + [rec(200), rec(201, 200, name: "Finder")])
        _ = await rig.controller.execute(await rig.controller.plan([target(rec(200))], includeDescendants: true, action: .pause))
        #expect(rig.sink.lines.count == 2)
        #expect(rig.sink.lines.map(\.result) == ["done", "refused:denylisted"])
        #expect(rig.sink.lines[1].root == "worker")
        #expect(Set(rig.sink.lines.map(\.flowID)).count == 1)
    }
}

@Suite struct AutoResumeTests {
    private func pause(_ rig: Rig) async {
        _ = await rig.controller.execute(await rig.controller.plan([target(rec(200))], includeDescendants: false, action: .pause))
    }
    @Test func resumesAtResumeAtNotBefore() async throws {
        let rig = try Rig(base + [rec(200)], minutes: 15)
        await pause(rig)
        rig.clock.advance(14 * 60)
        #expect(await rig.controller.resumeDue().isEmpty)
        rig.clock.advance(61)
        let r = await rig.controller.resumeDue()
        #expect(r.map(\.outcome) == [.done])
        #expect(rig.signaler.calls.last == .init(kind: "sig", pid: 200, value: SIGCONT))
        #expect(await rig.controller.state().paused.isEmpty)
        #expect(PausedProcessStore(fileURL: rig.storeURL).load().isEmpty)
    }
    @Test func autoResumeMinutesAreClamped() async throws {
        let rig = try Rig(base + [rec(200)], minutes: 100_000)
        await pause(rig)
        let e = await rig.controller.state().paused[0]
        #expect(e.resumeAt.timeIntervalSince(e.pausedAt) == 60 * 60, "never longer than 60 min, never forever")
    }
    @Test func pausedEntryIsPersistedBeforeAnySignal() async throws {
        let rig = try Rig(base + [rec(200)])
        await pause(rig)
        #expect(PausedProcessStore(fileURL: rig.storeURL).load().map(\.pid) == [200])
        var st = stat(); #expect(stat(rig.storeURL.path, &st) == 0); #expect(st.st_mode & 0o777 == 0o600)
    }
    @Test func quitResumesAll() async throws {
        let rig = try Rig(base + [rec(200), rec(201, 200)])
        _ = await rig.controller.execute(await rig.controller.plan([target(rec(200))], includeDescendants: true, action: .pause))
        _ = await rig.controller.resumeAll()
        #expect(rig.signaler.calls.filter { $0.value == SIGCONT }.map(\.pid) == [201, 200])
        #expect(await rig.controller.state().paused.isEmpty)
    }
    @Test func resumeAfterPidReuseSendsNothing() async throws {
        let rig = try Rig(base + [rec(200)])
        await pause(rig)
        rig.table.records = base + [rec(200, start: 424_242)]
        let r = await rig.controller.resumeAll()
        #expect(r.first?.outcome == .refused(.identityChanged))
        #expect(rig.signaler.calls.filter { $0.value == SIGCONT }.isEmpty)
        #expect(await rig.controller.state().paused.isEmpty, "the stale entry is dropped")
    }
    @Test func recoveryOffersOnlyStoppedProcessesWithMatchingIdentity() async throws {
        let dir = try TemporaryDirectory()
        let store = PausedProcessStore(fileURL: dir.url.appendingPathComponent("paused.json"))
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        let mk = { (pid: pid_t, start: UInt64) in PausedProcess(pid: pid, startID: start, name: "p\(pid)", pausedAt: t, resumeAt: t.addingTimeInterval(900)) }
        try store.save([mk(200, 2000), mk(201, 2010), mk(202, 2020), mk(203, 2030)])
        let table = FakeTable(base + [
            rec(200, start: 2000, status: UInt32(SSTOP)),      // still stopped, same process: offered
            rec(201, start: 2010, status: 2),                   // running again: dropped
            rec(202, start: 9999, status: UInt32(SSTOP)),       // pid reused: dropped
        ])                                                      // 203 gone: dropped
        let signaler = FakeSignaler()
        let c = ProcessController(table: table, signaler: signaler, store: store, isGUIApp: { _ in false }, ownPID: ownPID, ownUID: me)
        #expect(await c.recoveryCandidates().map(\.pid) == [200])
        #expect(store.load().map(\.pid) == [200])
        #expect(signaler.calls.isEmpty, "recovery itself never signals")
    }
    @Test func leavePausedRestartsTheClock() async throws {
        let rig = try Rig(base + [rec(200)], minutes: 10)
        await pause(rig)
        rig.clock.advance(9 * 60)
        await rig.controller.rearmAll()
        rig.clock.advance(5 * 60)
        #expect(await rig.controller.resumeDue().isEmpty)
        rig.clock.advance(6 * 60)
        #expect(await rig.controller.resumeDue().count == 1)
    }
}

@Suite struct KeepChildrenInBackgroundTests {
    @Test func newDescendantIsBackgroundedOnce() async throws {
        let rig = try Rig(base + [rec(200)])
        await rig.controller.setKeepChildrenInBackground([target(rec(200))], on: true)
        #expect(await rig.controller.tickKeepChildren().isEmpty)
        rig.table.records = base + [rec(200), rec(300, 200), rec(301, 300)]
        let first = await rig.controller.tickKeepChildren()
        #expect(first.map(\.target.pid) == [300, 301])
        #expect(await rig.controller.tickKeepChildren().isEmpty, "audited and applied once per pid")
        #expect(rig.signaler.calls.map(\.pid) == [300, 301])
        #expect(rig.signaler.calls.allSatisfy { $0.kind == "bg" && $0.value == 1 })
        #expect(rig.sink.lines.count == 2)
    }
    @Test func lapsesWhenTheRootExits() async throws {
        let rig = try Rig(base + [rec(200)])
        await rig.controller.setKeepChildrenInBackground([target(rec(200))], on: true)
        rig.table.records = base
        _ = await rig.controller.tickKeepChildren()
        #expect(await rig.controller.state().keepingChildren.isEmpty)
        rig.table.records = base + [rec(200), rec(300, 200)]
        #expect(await rig.controller.tickKeepChildren().isEmpty)
    }
    @Test func childrenStillGoThroughThePolicy() async throws {
        let rig = try Rig(base + [rec(200)])
        await rig.controller.setKeepChildrenInBackground([target(rec(200))], on: true)
        rig.table.records = base + [rec(200), rec(300, 200, name: "Dock")]
        let r = await rig.controller.tickKeepChildren()
        #expect(r.first?.outcome == .refused(.denylisted("Dock")))
        #expect(rig.signaler.calls.isEmpty)
    }
}

@Suite struct LiveSignalingGuardTests {
    // The live signaler refuses everything but SIGSTOP/SIGCONT and pid <= 1 before any syscall: these never reach kill(2).
    @Test func refusesDangerousArguments() {
        let s = LiveProcessSignaling()
        for sig in [SIGKILL, SIGTERM, SIGINT, SIGHUP, 0] { #expect(s.signal(12345, sig) == EINVAL) }
        for pid: pid_t in [-1, 0, 1] { #expect(s.signal(pid, SIGSTOP) == EINVAL); #expect(s.setBackground(pid, true) == EINVAL) }
    }
}

@Suite struct AuditHistoryProcessControlTests {
    @Test func processLinesAreGroupedAndNeverCountedInBytes() throws {
        let flow = UUID(), run = UUID()
        let p = { (pid: Int32, result: String, t: Double) in
            ProcessControlAuditRecord(timestamp: Date(timeIntervalSince1970: t), flowID: flow, action: "pause", pid: pid, name: "w",
                                      root: nil, result: result, errno: nil)
        }
        let c = AuditRecord(timestamp: Date(timeIntervalSince1970: 1_700_000_000), runID: run, itemID: "i", path: "/a", bytes: 500,
                            action: .trash, result: "trashed", trashPath: "/Users/x/.Trash/a", ruleID: "r", tool: "npm", reasons: [], error: nil)
        let enc = DiskKeeperJSON.makeEncoder()
        var data = Data()
        for line in [try enc.encode(p(10, "done", 1_700_000_100)), try enc.encode(p(11, "refused:denylisted", 1_700_000_101)),
                     try enc.encode(c)] { data.append(line); data.append(0x0A) }
        let h = AuditHistoryReader.parse(data)
        #expect(h.runs.count == 2)
        let proc = try #require(h.runs.first { $0.kind == .processControl })
        #expect(proc.processes.count == 2 && proc.bytesReclaimed == 0 && proc.items == 0)
        #expect(h.lifetimeReclaimed == 500)
        #expect(h.unknownLines == 0 && h.malformedLines == 0)
        #expect(AuditCSV.export(h).contains("process:pause"))
    }
}

@Suite struct AutoResumeSettingsTests {
    @Test func defaultsAndClamping() throws {
        #expect(AppSettings.defaults.autoResumeMinutes == 15)
        let old = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        #expect(old.autoResumeMinutes == 15, "an old settings file decodes with the default")
        let wild = try JSONDecoder().decode(AppSettings.self, from: Data("{\"autoResumeMinutes\": 100000}".utf8))
        #expect(wild.autoResumeMinutes == 60)
        #expect(AppSettings.clampAutoResume(0) == 1)
    }
}

/// The ONLY live test: it spawns its own child (a copy of `sleep`, because system paths are refused by policy) and
/// signals nothing else. The child is always SIGKILLed by test code in `defer`.
@Suite(.serialized) struct LiveChildProcessTests {
    private func status(_ pid: pid_t) -> UInt32? {
        LibprocProcessTable().snapshot()?.records.first { $0.pid == pid }?.status
    }
    private func wait(_ pid: pid_t, until predicate: (UInt32) -> Bool) async -> Bool {
        for _ in 0..<40 {
            if let s = status(pid), predicate(s) { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    @Test func backgroundPauseResumeOnItsOwnChild() async throws {
        let dir = try TemporaryDirectory()
        let exe = dir.path("sleepcopy")
        try FileManager.default.copyItem(atPath: "/bin/sleep", toPath: exe)
        let child = Process()
        child.executableURL = URL(fileURLWithPath: exe)
        child.arguments = ["60"]
        child.currentDirectoryURL = dir.url
        try child.run()
        let pid = child.processIdentifier
        defer { kill(pid, SIGKILL); child.waitUntilExit() }   // test code only, own child only

        let table = LibprocProcessTable()
        let rec = try #require(table.snapshot()?.records.first { $0.pid == pid })
        let t = ProcessTarget(pid: pid, startID: rec.startID, name: rec.name)
        let store = PausedProcessStore(fileURL: dir.url.appendingPathComponent("paused.json"))
        let c = ProcessController(table: table, signaler: LiveProcessSignaling(), store: store, isGUIApp: { _ in false })

        _ = await c.execute(await c.plan([t], includeDescendants: false, action: .background))
        #expect(getpriority(PRIO_DARWIN_PROCESS, id_t(pid)) == 1, "PRIO_DARWIN_BG reads back as 1")
        _ = await c.execute(await c.plan([t], includeDescendants: false, action: .restorePriority))
        #expect(getpriority(PRIO_DARWIN_PROCESS, id_t(pid)) == 0)

        _ = await c.execute(await c.plan([t], includeDescendants: false, action: .pause))
        #expect(await wait(pid) { $0 == UInt32(SSTOP) })
        #expect(store.load().map(\.pid) == [pid])

        _ = await c.resumeAll()
        #expect(await wait(pid) { $0 != UInt32(SSTOP) })
        #expect(store.load().isEmpty)
    }
}
