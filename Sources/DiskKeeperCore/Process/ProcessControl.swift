import Darwin
import Foundation

// Process control (H5): lower a process's priority, or pause and resume it. The only signals this module ever sends
// are SIGSTOP and SIGCONT; the only priority call is `setpriority(PRIO_DARWIN_PROCESS, …, PRIO_DARWIN_BG)`.
// Nothing here kills a process, and nothing runs without a user-confirmed plan.

public enum ProcessAction: String, Codable, Sendable { case background, restorePriority, pause, resume }

/// A process as the user chose it. `startID` is the identity guard against pid reuse.
public struct ProcessTarget: Sendable, Hashable, Codable {
    public let pid: pid_t
    public let startID: UInt64
    public let name: String
    public init(pid: pid_t, startID: UInt64, name: String) { self.pid = pid; self.startID = startID; self.name = name }
    public var key: ProcessKey { ProcessKey(pid: pid, startID: startID) }
}

public enum ProcessRefusal: Sendable, Hashable {
    case otherUser, systemProcess, ownProcessOrAncestor, guiAppPause, launchd, identityChanged, vanished
    case denylisted(String)
    /// The executable path can't be read, so "is it a system process?" can't be answered: refused.
    case unreadablePath
}

/// The two calls product code may make on another process. Tests fake this; `LiveProcessSignaling` is the real one.
public protocol ProcessSignaling: Sendable {
    /// `setpriority(PRIO_DARWIN_PROCESS, pid, on ? PRIO_DARWIN_BG : 0)`. 0 = success, otherwise errno.
    func setBackground(_ pid: pid_t, _ on: Bool) -> Int32
    /// `kill(pid, SIGSTOP | SIGCONT)` only. 0 = success, otherwise errno.
    func signal(_ pid: pid_t, _ sig: Int32) -> Int32
}

public struct LiveProcessSignaling: ProcessSignaling {
    public init() {}

    public func setBackground(_ pid: pid_t, _ on: Bool) -> Int32 {
        guard pid > 1 else { return EINVAL }
        return setpriority(PRIO_DARWIN_PROCESS, id_t(pid), on ? PRIO_DARWIN_BG : 0) == 0 ? 0 : errno
    }

    /// Anything but SIGSTOP / SIGCONT is refused here, whatever the caller asks. `pid > 1` also rules out the
    /// process-group (0, negative) and broadcast (-1) forms of kill(2).
    public func signal(_ pid: pid_t, _ sig: Int32) -> Int32 {
        guard pid > 1, sig == SIGSTOP || sig == SIGCONT else { return EINVAL }
        return kill(pid, sig) == 0 ? 0 : errno
    }
}

public enum ProcessControlPolicy {
    static let systemPrefixes = ["/System/", "/usr/", "/sbin/", "/bin/", "/Library/Apple/"]
    static let allowedUnderUsr = "/usr/local/"
    public static let denylist: Set<String> = [
        "WindowServer", "loginwindow", "Finder", "Dock", "SystemUIServer", "ControlCenter", "coreaudiod", "launchservicesd",
    ]
    /// `pbi_status` of a stopped process.
    public static let stoppedStatus = UInt32(SSTOP)

    /// nil = allowed. Each process is judged on its own. Resume and restore-priority only undo what this app did, so
    /// they are refused for another user's process or pid ≤ 1 and nothing else: a process must never stay stopped
    /// because a later policy change would no longer allow pausing it.
    public static func refusal(_ r: ProcessRecord, action: ProcessAction, ownPID: pid_t, ownAncestors: Set<pid_t>,
                               isGUIApp: Bool, ownUID: uid_t = getuid()) -> ProcessRefusal? {
        if r.uid != ownUID { return .otherUser }
        if r.pid <= 1 { return .launchd }
        if action == .resume || action == .restorePriority { return nil }
        if r.pid == ownPID || ownAncestors.contains(r.pid) { return .ownProcessOrAncestor }
        guard let path = r.executablePath else { return .unreadablePath }
        if systemPrefixes.contains(where: { path.hasPrefix($0) }) && !path.hasPrefix(allowedUnderUsr) { return .systemProcess }
        if denylist.contains(r.name) { return .denylisted(r.name) }
        if action == .pause && isGUIApp { return .guiAppPause }
        return nil
    }
}

public extension ProcessControlPolicy {
    /// This process's parent chain read straight from libproc, for any owner (stops at pid <= 1 or a loop).
    static func liveAncestors(of pid: pid_t = getpid()) -> Set<pid_t> {
        var out = Set<pid_t>(), cursor = pid
        while out.count < 64 {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(cursor, PROC_PIDTBSDINFO, 0, &info, size) == size else { break }
            let parent = pid_t(bitPattern: info.pbi_ppid)
            guard parent > 0, out.insert(parent).inserted else { break }
            cursor = parent
        }
        return out
    }
}

public struct ProcessControlPlanRow: Sendable, Hashable {
    public let target: ProcessTarget
    public let ppid: pid_t
    /// One of the processes the user picked (not a descendant added by "include child processes").
    public let isRoot: Bool
    public let refusal: ProcessRefusal?
}

public struct ProcessControlPlan: Sendable {
    public let action: ProcessAction
    /// In the order the signals are sent: pause and background parent first, resume children first.
    public let rows: [ProcessControlPlanRow]
    public let includeDescendants: Bool
    public var actionable: [ProcessControlPlanRow] { rows.filter { $0.refusal == nil } }
}

public struct ProcessControlResult: Sendable, Hashable {
    public enum Outcome: Sendable, Hashable { case done, refused(ProcessRefusal), failed(errno: Int32) }
    public let target: ProcessTarget
    public let action: ProcessAction
    public let outcome: Outcome
}

public struct ProcessControlState: Sendable, Equatable {
    public var paused: [PausedProcess] = []
    public var backgrounded: Set<ProcessKey> = []
    /// Roots whose new child processes are kept in background.
    public var keepingChildren: Set<ProcessKey> = []
    public init(paused: [PausedProcess] = [], backgrounded: Set<ProcessKey> = [], keepingChildren: Set<ProcessKey> = []) {
        self.paused = paused; self.backgrounded = backgrounded; self.keepingChildren = keepingChildren
    }
}

public actor ProcessController {
    public static let autoResumeRange = 1...60

    private let table: any ProcessTableReading
    private let signaler: any ProcessSignaling
    private let store: PausedProcessStore
    private let isGUIApp: @Sendable (pid_t) -> Bool
    private let ownPID: pid_t
    private let ownUID: uid_t
    private let extraAncestors: @Sendable () -> Set<pid_t>
    private let now: @Sendable () -> Date
    private let audit: @Sendable (ProcessControlAuditRecord) async -> Void
    private var autoResumeMinutes: Int
    /// One confirmed action (or one sampler tick, or one resume pass) = one flow = one History row.
    private var flowID = UUID()

    private var paused: [PausedProcess]
    private var backgrounded: Set<ProcessKey> = []
    private var keepRoots: [ProcessKey: ProcessTarget] = [:]
    private var keptHandled: Set<ProcessKey> = []

    public init(table: any ProcessTableReading, signaler: any ProcessSignaling, store: PausedProcessStore,
                isGUIApp: @escaping @Sendable (pid_t) -> Bool, ownPID: pid_t = getpid(), ownUID: uid_t = getuid(),
                extraAncestors: @escaping @Sendable () -> Set<pid_t> = { [] },
                now: @escaping @Sendable () -> Date = { Date() },
                autoResumeMinutes: Int = AppSettings.defaultAutoResumeMinutes,
                audit: @escaping @Sendable (ProcessControlAuditRecord) async -> Void = { _ in }) {
        self.table = table; self.signaler = signaler; self.store = store; self.isGUIApp = isGUIApp
        self.ownPID = ownPID; self.ownUID = ownUID; self.extraAncestors = extraAncestors; self.now = now; self.autoResumeMinutes = autoResumeMinutes
        self.audit = audit
        self.paused = store.load()
    }

    /// Takes effect for the next pause (and for "Leave paused"); already-paused processes keep their time.
    public func setAutoResumeMinutes(_ m: Int) { autoResumeMinutes = m }

    public func state() -> ProcessControlState {
        ProcessControlState(paused: paused, backgrounded: backgrounded, keepingChildren: Set(keepRoots.keys))
    }

    // MARK: Plan

    /// A preview, nothing is signalled. Every member of a tree is checked on its own.
    public func plan(_ targets: [ProcessTarget], includeDescendants: Bool, action: ProcessAction) -> ProcessControlPlan {
        guard let snap = table.snapshot() else {
            return ProcessControlPlan(action: action, rows: targets.map {
                ProcessControlPlanRow(target: $0, ppid: 0, isRoot: true, refusal: .vanished)
            }, includeDescendants: includeDescendants)
        }
        let byPID = Dictionary(snap.records.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        let ancestors = ownAncestors(in: snap)
        var rows: [ProcessControlPlanRow] = []
        var seen = Set<pid_t>()
        for t in targets {
            guard let rec = byPID[t.pid] else {
                rows.append(ProcessControlPlanRow(target: t, ppid: 0, isRoot: true, refusal: .vanished)); continue
            }
            guard rec.startID == t.startID else {
                rows.append(ProcessControlPlanRow(target: t, ppid: rec.ppid, isRoot: true, refusal: .identityChanged)); continue
            }
            let members = [rec] + (includeDescendants ? snap.descendants(of: rec.pid) : [])
            for (i, m) in members.enumerated() where seen.insert(m.pid).inserted {
                rows.append(ProcessControlPlanRow(
                    target: ProcessTarget(pid: m.pid, startID: m.startID, name: m.name), ppid: m.ppid, isRoot: i == 0,
                    refusal: ProcessControlPolicy.refusal(m, action: action, ownPID: ownPID, ownAncestors: ancestors,
                                                          isGUIApp: isGUIApp(m.pid), ownUID: ownUID)))
            }
        }
        if action == .resume { rows.reverse() }   // children first
        return ProcessControlPlan(action: action, rows: rows, includeDescendants: includeDescendants)
    }

    // MARK: Execute

    /// Runs a confirmed plan. Before every single signal the process is looked up again (fresh table) and must still
    /// have the same `(pid, startID)` and pass the policy; otherwise nothing is sent for it.
    public func execute(_ plan: ProcessControlPlan) async -> [ProcessControlResult] {
        flowID = UUID()
        var results: [ProcessControlResult] = []
        let rootName = plan.rows.first(where: \.isRoot)?.target.name
        for row in plan.rows {
            let outcome: ProcessControlResult.Outcome
            if let r = row.refusal { outcome = .refused(r) } else { outcome = perform(plan.action, row.target) }
            let result = ProcessControlResult(target: row.target, action: plan.action, outcome: outcome)
            results.append(result)
            await record(result, root: row.isRoot ? nil : rootName)
        }
        return results
    }

    /// Identity guard + policy + one signal for one process.
    private func perform(_ action: ProcessAction, _ t: ProcessTarget) -> ProcessControlResult.Outcome {
        guard let snap = table.snapshot(), let rec = snap.records.first(where: { $0.pid == t.pid }) else { return .refused(.vanished) }
        guard rec.startID == t.startID else { return .refused(.identityChanged) }
        let ancestors = ownAncestors(in: snap)
        if let r = ProcessControlPolicy.refusal(rec, action: action, ownPID: ownPID, ownAncestors: ancestors,
                                                isGUIApp: isGUIApp(rec.pid), ownUID: ownUID) { return .refused(r) }
        switch action {
        case .background:
            let rc = signaler.setBackground(t.pid, true)
            if rc == 0 { backgrounded.insert(t.key) }
            return rc == 0 ? .done : .failed(errno: rc)
        case .restorePriority:
            let rc = signaler.setBackground(t.pid, false)
            if rc == 0 { backgrounded.remove(t.key) }
            return rc == 0 ? .done : .failed(errno: rc)
        case .pause:
            // Persist first: if the app dies right after the signal, the recovery sheet still knows about it.
            let stamp = now()
            let entry = PausedProcess(pid: t.pid, startID: t.startID, name: t.name, pausedAt: stamp,
                                      resumeAt: stamp.addingTimeInterval(Double(resumeMinutes()) * 60))
            let before = paused
            paused.removeAll { $0.key == t.key }
            paused.append(entry)
            persist()
            let rc = signaler.signal(t.pid, SIGSTOP)
            if rc != 0 { paused = before; persist() }
            return rc == 0 ? .done : .failed(errno: rc)
        case .resume:
            let rc = signaler.signal(t.pid, SIGCONT)
            if rc == 0 { paused.removeAll { $0.key == t.key }; persist() }
            return rc == 0 ? .done : .failed(errno: rc)
        }
    }

    /// Our ancestor chain from the (own-uid) table, plus the live chain (`extraAncestors`), which also crosses root-owned
    /// hops such as `login` that an own-uid table can't see.
    private func ownAncestors(in snap: ProcessTableSnapshot) -> Set<pid_t> {
        Set(snap.ancestors(of: ownPID).map(\.pid)).union(extraAncestors())
    }

    private func resumeMinutes() -> Int {
        min(max(autoResumeMinutes, Self.autoResumeRange.lowerBound), Self.autoResumeRange.upperBound)
    }

    private func persist() { try? store.save(paused) }

    private func record(_ r: ProcessControlResult, root: String?) async {
        let result: String, code: Int32?
        switch r.outcome {
        case .done: result = "done"; code = nil
        case .refused(let why): result = "refused:\(Self.code(why))"; code = nil
        case .failed(let e): result = "failed"; code = e
        }
        await audit(ProcessControlAuditRecord(timestamp: now(), flowID: flowID, action: r.action.rawValue, pid: r.target.pid,
                                              name: r.target.name, root: root, result: result, errno: code))
    }

    public static func code(_ r: ProcessRefusal) -> String {
        switch r {
        case .otherUser: "otherUser"
        case .systemProcess: "systemProcess"
        case .ownProcessOrAncestor: "ownProcessOrAncestor"
        case .guiAppPause: "guiAppPause"
        case .launchd: "launchd"
        case .identityChanged: "identityChanged"
        case .vanished: "vanished"
        case .denylisted: "denylisted"
        case .unreadablePath: "unreadablePath"
        }
    }

    // MARK: Pause lifecycle

    /// Resumes everything past its `resumeAt`. Driven by a timer in the UI model (and by tests with a fake clock).
    @discardableResult
    public func resumeDue() async -> [ProcessControlResult] {
        let t = now()
        return await resume(paused.filter { $0.resumeAt <= t })
    }

    /// Quit, "Resume all" and the recovery sheet. Children first. An entry whose process is gone or was replaced (new
    /// `startID`) is dropped without a signal.
    @discardableResult
    public func resumeAll() async -> [ProcessControlResult] { await resume(paused) }

    private func resume(_ entries: [PausedProcess]) async -> [ProcessControlResult] {
        guard !entries.isEmpty else { return [] }
        flowID = UUID()
        let snap = table.snapshot()
        let depth = { (e: PausedProcess) in snap?.ancestors(of: e.pid).count ?? 0 }
        var results: [ProcessControlResult] = []
        for e in entries.sorted(by: { depth($0) > depth($1) }) {
            let t = ProcessTarget(pid: e.pid, startID: e.startID, name: e.name)
            let outcome = perform(.resume, t)
            // One audited attempt per entry: done, refused, vanished or failed, it is not retried (and not re-audited).
            paused.removeAll { $0.key == e.key }
            persist()
            let result = ProcessControlResult(target: t, action: .resume, outcome: outcome)
            results.append(result)
            await record(result, root: nil)
        }
        return results
    }

    /// At launch: the entries whose process is still stopped and still the same process. The rest are dropped.
    public func recoveryCandidates() -> [PausedProcess] {
        let snap = table.snapshot()
        let live = Dictionary((snap?.records ?? []).map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        paused = paused.filter {
            guard $0.pid > 1, let r = live[$0.pid] else { return false }
            // Same policy as a resume: another user's process or pid <= 1 is never offered.
            guard ProcessControlPolicy.refusal(r, action: .resume, ownPID: ownPID, ownAncestors: [], isGUIApp: false,
                                               ownUID: ownUID) == nil else { return false }
            return r.startID == $0.startID && r.status == ProcessControlPolicy.stoppedStatus
        }
        persist()
        return paused
    }

    /// "Leave paused" on the recovery sheet: nothing stays paused without an auto-resume time, so the clock restarts.
    public func rearmAll() {
        let at = now().addingTimeInterval(Double(resumeMinutes()) * 60)
        for i in paused.indices { paused[i].resumeAt = at }
        persist()
    }

    // MARK: Keep new children in background (D9)

    /// Turning it on records the descendants that exist right now as already handled: children the user left out of the
    /// plan ("Include child processes" off) are never touched, only processes that appear later.
    public func setKeepChildrenInBackground(_ roots: [ProcessTarget], on: Bool) {
        let snap = on ? table.snapshot() : nil
        for r in roots {
            if on {
                keepRoots[r.key] = r
                for d in snap?.descendants(of: r.pid) ?? [] { keptHandled.insert(ProcessKey(pid: d.pid, startID: d.startID)) }
            } else { keepRoots[r.key] = nil }
        }
    }

    /// One sampler tick: a root that exited (or whose pid was reused) lapses; every descendant not seen before is put
    /// in background and audited once. Session only: nothing here is persisted.
    @discardableResult
    public func tickKeepChildren() async -> [ProcessControlResult] {
        guard !keepRoots.isEmpty, let snap = table.snapshot() else { return [] }
        flowID = UUID()
        let live = Dictionary(snap.records.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        for (key, _) in keepRoots where live[key.pid]?.startID != key.startID { keepRoots[key] = nil }
        var results: [ProcessControlResult] = []
        for root in keepRoots.values {
            for child in snap.descendants(of: root.pid) {
                let key = ProcessKey(pid: child.pid, startID: child.startID)
                guard keptHandled.insert(key).inserted else { continue }
                let t = ProcessTarget(pid: child.pid, startID: child.startID, name: child.name)
                let outcome = perform(.background, t)
                let result = ProcessControlResult(target: t, action: .background, outcome: outcome)
                results.append(result)
                await record(result, root: root.name)
            }
        }
        // Forget processes that are gone, so the sets stay small.
        let liveKeys = Set(snap.records.map { ProcessKey(pid: $0.pid, startID: $0.startID) })
        keptHandled.formIntersection(liveKeys)
        backgrounded.formIntersection(liveKeys)
        return results
    }
}
