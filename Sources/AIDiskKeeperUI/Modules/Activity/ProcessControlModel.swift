import AppKit
import DiskKeeperCore
import Foundation
import Observation

/// UI state of process control: the confirmation sheet, the paused list, crash recovery and the one timer that
/// resumes paused processes and keeps new children in background. The timer runs only while there is something
/// paused or watched; with nothing to do the model does no work.
@MainActor @Observable
final class ProcessControlModel {
    enum Sheet: Identifiable {
        case confirm, recovery
        var id: Int { self == .confirm ? 0 : 1 }
    }

    var sheet: Sheet?
    private(set) var plan: ProcessControlPlan?
    private(set) var state = ProcessControlState()
    private(set) var recovery: [PausedProcess] = []
    /// Failures of the last confirmed action, shown once under the list.
    private(set) var failures: [ProcessControlResult] = []
    var includeDescendants = true
    var keepChildrenInBackground = false

    let controller: ProcessController
    @ObservationIgnored private let settings: SettingsModel?
    @ObservationIgnored private let sleeper: @Sendable (Duration) async -> Void
    @ObservationIgnored private var pendingTargets: [ProcessTarget] = []
    @ObservationIgnored private var pendingAction: ProcessAction = .pause
    @ObservationIgnored private var loop: Task<Void, Never>?

    init(controller: ProcessController, settings: SettingsModel?,
         sleeper: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0, tolerance: $0 / 5) }) {
        self.controller = controller
        self.settings = settings
        self.sleeper = sleeper
    }

    /// The real wiring: libproc table, the real signals, `paused.json` and `audit.jsonl` under Application Support.
    static func live(environment: PathEnvironment, settings: SettingsModel) -> ProcessControlModel {
        let log = AuditLog(fileURL: AuditLog.defaultURL(environment: environment))
        let controller = ProcessController(
            table: LibprocProcessTable(), signaler: LiveProcessSignaling(),
            store: PausedProcessStore(fileURL: PausedProcessStore.defaultURL(environment: environment)),
            isGUIApp: { pid in NSWorkspace.shared.runningApplications.contains { $0.processIdentifier == pid && $0.activationPolicy == .regular } },
            extraAncestors: { ProcessControlPolicy.liveAncestors() },
            autoResumeMinutes: settings.settings.autoResumeMinutes,
            audit: { record in try? await log.appendProcessControlEvent(record) })
        return ProcessControlModel(controller: controller, settings: settings)
    }

    var pausedCount: Int { state.paused.count }
    var autoResumeMinutes: Int { settings?.settings.autoResumeMinutes ?? AppSettings.defaultAutoResumeMinutes }
    func isBackground(_ key: ProcessKey) -> Bool { state.backgrounded.contains(key) }
    func pausedEntry(_ key: ProcessKey) -> PausedProcess? { state.paused.first { $0.key == key } }

    // MARK: Requests

    /// Builds the preview and opens the confirmation sheet. Nothing is signalled yet.
    func request(_ action: ProcessAction, _ targets: [ProcessTarget]) async {
        guard !targets.isEmpty else { return }
        await controller.setAutoResumeMinutes(autoResumeMinutes)
        pendingTargets = targets
        pendingAction = action
        failures = []
        includeDescendants = true
        keepChildrenInBackground = false
        plan = await controller.plan(targets, includeDescendants: true, action: action)
        sheet = .confirm
    }

    func setIncludeDescendants(_ on: Bool) async {
        includeDescendants = on
        plan = await controller.plan(pendingTargets, includeDescendants: on, action: pendingAction)
    }

    func cancel() { sheet = nil; plan = nil }

    func confirm() async {
        guard let plan else { return }
        sheet = nil
        self.plan = nil
        await controller.setAutoResumeMinutes(autoResumeMinutes)
        let results = await controller.execute(plan)
        if plan.action == .background, keepChildrenInBackground {
            let roots = plan.rows.filter { $0.isRoot && $0.refusal == nil }.map(\.target)
            await controller.setKeepChildrenInBackground(roots, on: true)
        }
        failures = results.filter { $0.outcome != .done }
        await refresh()
    }

    /// One-click undo of what this app did: SIGCONT / priority back. Only for processes it changed.
    func resume(_ entry: PausedProcess) async {
        let target = ProcessTarget(pid: entry.pid, startID: entry.startID, name: entry.name)
        let plan = await controller.plan([target], includeDescendants: false, action: .resume)
        _ = await controller.execute(plan)
        await refresh()
    }

    func restorePriority(_ target: ProcessTarget) async {
        let plan = await controller.plan([target], includeDescendants: false, action: .restorePriority)
        _ = await controller.execute(plan)
        await controller.setKeepChildrenInBackground([target], on: false)
        await refresh()
    }

    func resumeAll() async {
        _ = await controller.resumeAll()
        await refresh()
    }

    // MARK: Crash recovery and quit

    /// At launch: processes this app paused before it last closed and that are still stopped.
    func checkRecovery() async {
        recovery = await controller.recoveryCandidates()
        if !recovery.isEmpty { sheet = .recovery }
        await refresh()
    }

    func recoveryResumeAll() async {
        sheet = nil
        recovery = []
        await resumeAll()
    }

    func recoveryLeave() async {
        sheet = nil
        recovery = []
        await controller.rearmAll()
        await refresh()
    }

    /// Quit: nothing this app paused stays paused.
    func resumeAllForQuit() async {
        loop?.cancel()
        _ = await controller.resumeAll()
        state = await controller.state()
    }

    // MARK: State and timer

    func refresh() async {
        state = await controller.state()
        let needsLoop = !state.paused.isEmpty || !state.keepingChildren.isEmpty
        if needsLoop, loop == nil {
            loop = Task { [weak self] in await self?.run() }
        } else if !needsLoop {
            loop?.cancel()
            loop = nil
        }
    }

    private func run() async {
        while !Task.isCancelled {
            await sleeper(.seconds(5))
            if Task.isCancelled { break }
            _ = await controller.resumeDue()
            _ = await controller.tickKeepChildren()
            state = await controller.state()
            if state.paused.isEmpty, state.keepingChildren.isEmpty { break }
        }
        if !Task.isCancelled { loop = nil }
    }

    /// "12 min" or "under a minute".
    static func remaining(until date: Date, now: Date = Date()) -> String {
        let seconds = date.timeIntervalSince(now)
        return seconds < 60 ? ProcessControlCopy.lessThanMinute : ProcessControlCopy.minutes(Int((seconds / 60).rounded(.up)))
    }
}
