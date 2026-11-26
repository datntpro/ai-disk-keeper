import DiskKeeperCore
import Foundation
import os

/// Where one "Quit App" press is. One flow per app id; it keeps running if the user selects another app.
enum QuitFlowState: Equatable {
    case quitting, stuck, forcing, settling, done, failed, relaunched, backgroundRemains
    case refused(AppQuitRefusal)
    case auditFailed

    var isBusy: Bool { self == .quitting || self == .forcing || self == .settling }
    /// The app is still open and the user may ask again or force quit.
    var isStuck: Bool { self == .stuck || self == .failed || self == .auditFailed }
    /// Quit may be pressed (again): nothing in progress, or the last attempt ended with something still open.
    var allowsQuit: Bool { isStuck || self == .relaunched || self == .backgroundRemains }
}

/// Who we are, so the quit policy can refuse to act on ourselves.
struct SelfIdentity: Sendable {
    var bundleID: String?
    var path: String?
    var pid: pid_t
    var uid: uid_t

    @MainActor static var live: SelfIdentity {
        SelfIdentity(bundleID: Bundle.main.bundleIdentifier, path: Bundle.main.bundleURL.path, pid: getpid(), uid: getuid())
    }
}

/// What the Force Quit confirmation shows.
struct ForceConfirmation: Equatable {
    let appID: InstalledApp.ID
    let name: String
    let instances: Int
}

/// Timings (seconds). The app is never force quit automatically: a timeout only offers Force Quit.
enum QuitTiming {
    static let graceful: TimeInterval = 5
    static let force: TimeInterval = 3
    static let settle: TimeInterval = 1.5
    static let tick = Duration.milliseconds(250)
}

private let quitLog = Logger(subsystem: "com.aidiskkeeper", category: "uninstaller.quit")

extension UninstallerModel {
    typealias QuitAudit = @Sendable (AppQuitAuditRecord) async throws -> Void
    typealias Sleeper = @Sendable (Duration) async throws -> Void

    // MARK: Policy

    /// Why this app can't be offered Quit at all.
    func appRefusal(_ app: InstalledApp) -> AppQuitRefusal? {
        AppQuitPolicy.refusal(bundleID: app.bundleID, teamID: app.source.teamID, viewOnly: app.viewOnlyReason != nil,
                              bundlePath: app.path, selfBundleID: identity.bundleID, selfBundlePath: identity.path)
    }

    func instanceRefusal(_ i: AppInstance) -> AppQuitRefusal? {
        let owner: uid_t? = i.ownedByCurrentUser.map { $0 ? identity.uid : identity.uid &+ 1 }
        return AppQuitPolicy.refusal(pid: i.pid, bundleID: i.bundleID, ownerUID: owner, currentUID: identity.uid,
                                     selfPID: identity.pid, location: i.location, selfBundlePath: identity.path)
    }

    /// The instances Quit would ask: main and helper apps that pass the policy.
    func quitTargets(in state: AppRunState) -> [AppInstance] {
        state.instances.filter { $0.kind != .background && instanceRefusal($0) == nil }
    }

    func backgroundNames(in state: AppRunState) -> [String] {
        state.instances.filter { $0.kind == .background }.map { "\($0.name) (\($0.pid))" }
    }

    /// Quit App is offered: the app passes the policy, something quittable is open, and no flow is busy.
    func canQuit(_ app: InstalledApp) -> Bool {
        guard appRefusal(app) == nil, !runningUnknown, selectedAppID == app.id, let detail else { return false }
        let flow = quitFlows[app.id]
        return flow == nil || flow?.allowsQuit == true ? !quitTargets(in: detail).isEmpty : false
    }

    // MARK: Actions

    /// Asks the app to quit, like ⌘Q. It may ask the user to save; that is what the stuck state is for.
    func quit(_ app: InstalledApp, coordinator: CleanupCoordinator? = nil) {
        guard coordinator?.isPresented != true else { return }
        let flow = quitFlows[app.id]
        guard flow == nil || flow?.allowsQuit == true || flow == .done else { return }
        if let reason = appRefusal(app) {
            quitFlows[app.id] = .refused(reason)
            let flowID = UUID()
            Task { await record(app, flowID, mode: "graceful", phase: "result", result: "refused", targets: [], reasons: [reason.rawValue]) }
            return
        }
        guard let state = processes.runState(for: app) else { refreshRunning(); return }
        let targets = quitTargets(in: state)
        guard !targets.isEmpty else { refreshRunning(); return }
        let flowID = UUID()
        flowInfo[app.id] = (flowID, targets)
        quitFlows[app.id] = .quitting
        quitTasks[app.id]?.cancel()
        quitTasks[app.id] = Task { [weak self] in await self?.runGraceful(app, flowID, targets) }
    }

    /// Step 1 of Force Quit: ask the user. Nothing is signalled yet.
    func requestForceQuit(_ app: InstalledApp) {
        guard quitFlows[app.id]?.isStuck == true, appRefusal(app) == nil, let state = processes.runState(for: app) else { return }
        let count = quitTargets(in: state).count
        guard count > 0 else { return }
        forceConfirmation = ForceConfirmation(appID: app.id, name: app.name, instances: count)
    }

    func cancelForceQuit() { forceConfirmation = nil }

    func confirmForceQuit() {
        guard let c = forceConfirmation, let app = apps.first(where: { $0.id == c.appID }) else { forceConfirmation = nil; return }
        forceConfirmation = nil
        guard quitFlows[app.id]?.isStuck == true, appRefusal(app) == nil, let state = processes.runState(for: app) else { return }
        let targets = quitTargets(in: state)
        guard !targets.isEmpty else { refreshRunning(); return }
        let flowID = UUID()
        flowInfo[app.id] = (flowID, targets)
        quitFlows[app.id] = .forcing
        quitTasks[app.id]?.cancel()
        quitTasks[app.id] = Task { [weak self] in await self?.runForce(app, flowID, targets) }
    }

    /// Brings the app forward so the user can answer its save dialog.
    func showApp(_ app: InstalledApp) {
        guard appRefusal(app) == nil, let state = processes.runState(for: app),
              let first = quitTargets(in: state).first else { return }
        processes.activate(first)
    }

    // MARK: Flow

    private enum Wait { case gone, timeout, unreadable }

    private func runGraceful(_ app: InstalledApp, _ flowID: UUID, _ targets: [AppInstance]) async {
        await record(app, flowID, mode: "graceful", phase: "requested", result: nil, targets: targets)
        var accepted = 0
        for t in targets where processes.requestQuit(t) { accepted += 1 }
        guard accepted > 0 else { return await finishStuck(app, flowID, "graceful", targets) }
        switch await wait(app, timeout: QuitTiming.graceful) {
        case .gone: await settle(app, flowID, "graceful", targets)
        case .timeout: await finishStuck(app, flowID, "graceful", targets)
        case .unreadable: drop(app)
        }
    }

    private func runForce(_ app: InstalledApp, _ flowID: UUID, _ targets: [AppInstance]) async {
        // Fail closed: no force quit without a line in the audit log saying we are about to.
        do {
            try await audit(makeRecord(app, flowID, "force", "requested", nil, targets, [], nil))
        } catch {
            quitLog.error("audit log write failed before force quit: \(String(describing: error), privacy: .public)")
            if !Task.isCancelled { quitFlows[app.id] = .auditFailed }
            return
        }
        for t in targets { _ = processes.forceQuit(t) }
        switch await wait(app, timeout: QuitTiming.force) {
        case .gone: await settle(app, flowID, "force", targets)
        case .timeout:
            guard !Task.isCancelled else { return }
            quitFlows[app.id] = .failed
            await record(app, flowID, mode: "force", phase: "result", result: "stillRunning", targets: targets)
        case .unreadable: drop(app)
        }
    }

    private func finishStuck(_ app: InstalledApp, _ flowID: UUID, _ mode: String, _ targets: [AppInstance]) async {
        guard !Task.isCancelled else { return }
        quitFlows[app.id] = .stuck
        await record(app, flowID, mode: mode, phase: "result", result: "stillRunning", targets: targets)
    }

    /// Everything quittable is gone: wait a moment, look again, and say what is left.
    private func settle(_ app: InstalledApp, _ flowID: UUID, _ mode: String, _ targets: [AppInstance]) async {
        guard !Task.isCancelled else { return }
        quitFlows[app.id] = .settling
        try? await sleep(.milliseconds(Int(QuitTiming.settle * 1000)))
        guard !Task.isCancelled else { return }
        guard let state = processes.runState(for: app) else { return drop(app) }
        let outcome: String
        if !quitTargets(in: state).isEmpty { quitFlows[app.id] = .relaunched; outcome = "relaunched" }
        else if state.instances.contains(where: { $0.kind == .background }) { quitFlows[app.id] = .backgroundRemains; outcome = "backgroundRemains" }
        else { quitFlows[app.id] = .done; outcome = "quit" }
        flowInfo[app.id] = nil
        refreshRunning()
        await record(app, flowID, mode: mode, phase: "result", result: outcome, targets: targets)
    }

    private func wait(_ app: InstalledApp, timeout: TimeInterval) async -> Wait {
        let deadline = now().addingTimeInterval(timeout)
        while !Task.isCancelled {
            guard let state = processes.runState(for: app) else { return .unreadable }
            if quitTargets(in: state).isEmpty { return .gone }
            if now() >= deadline { return .timeout }
            try? await sleep(QuitTiming.tick)
        }
        return .timeout
    }

    /// The process list became unreadable mid-flow: stop, and let the screen say it can't tell.
    private func drop(_ app: InstalledApp) {
        guard !Task.isCancelled else { return }
        quitFlows[app.id] = nil
        refreshRunning()
    }

    /// The user answered the app's save dialog (or quit it by hand) while we were stuck: carry on to the end.
    func resumeStuckFlows() {
        for (id, state) in quitFlows where state.isStuck {
            guard let app = apps.first(where: { $0.id == id }), let s = processes.runState(for: app),
                  quitTargets(in: s).isEmpty else { continue }
            quitTasks[id]?.cancel()
            quitFlows[id] = .settling
            let info = flowInfo[id] ?? (UUID(), [])
            quitTasks[id] = Task { [weak self] in await self?.settle(app, info.id, "graceful", info.targets) }
        }
    }

    // MARK: Audit

    private func makeRecord(_ app: InstalledApp, _ flowID: UUID, _ mode: String, _ phase: String, _ result: String?,
                            _ targets: [AppInstance], _ reasons: [String], _ error: String?) -> AppQuitAuditRecord {
        AppQuitAuditRecord(timestamp: now(), flowID: flowID, bundleID: app.bundleID, appPath: app.path, mode: mode,
                           phase: phase, result: result, pids: targets.map { Int32($0.pid) }, instanceCount: targets.count,
                           reasons: reasons, error: error)
    }

    /// Best effort: a log failure must not stop a plain quit.
    private func record(_ app: InstalledApp, _ flowID: UUID, mode: String, phase: String, result: String?,
                        targets: [AppInstance], reasons: [String] = []) async {
        do { try await audit(makeRecord(app, flowID, mode, phase, result, targets, reasons, nil)) }
        catch { quitLog.error("audit log write failed: \(String(describing: error), privacy: .public)") }
    }
}
