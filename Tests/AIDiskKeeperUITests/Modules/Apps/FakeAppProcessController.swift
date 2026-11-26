import DiskKeeperCore
import Foundation
@testable import AIDiskKeeperUI

/// Stand-in for the live process controller. Tests never touch a real process: they script what is
/// "running" per app and read back which instances were asked to quit.
@MainActor final class FakeAppProcessController: AppProcessControlling {
    var states: [InstalledApp.ID: AppRunState] = [:]
    /// `true` makes both reads return nil (process list unreadable).
    var unreadable = false
    var quitResult = true
    var forceResult = true
    var onQuit: (AppInstance) -> Void = { _ in }
    var onForce: (AppInstance) -> Void = { _ in }
    private(set) var quits: [AppInstance] = []
    private(set) var forces: [AppInstance] = []
    private(set) var activations: [AppInstance] = []
    private(set) var runStateCalls = 0

    /// Order of acts, to prove audit lines come first.
    var log: [String] = []

    static func instance(_ kind: AppInstance.Kind = .main, pid: pid_t = 4242, name: String = "Notely", bundleID: String? = nil,
                         ours: Bool? = true) -> AppInstance {
        AppInstance(token: UUID(), pid: pid, kind: kind, name: name, bundleID: bundleID, location: nil, ownedByCurrentUser: ours)
    }

    func set(_ app: InstalledApp, _ instances: [AppInstance]) { states[app.id] = AppRunState(instances: instances) }
    func clear(_ app: InstalledApp) { states[app.id] = nil }

    func runningAppIDs(for apps: [InstalledApp]) -> Set<InstalledApp.ID>? {
        guard !unreadable else { return nil }
        return Set(apps.filter { states[$0.id]?.isRunning == true }.map(\.id))
    }

    func runState(for app: InstalledApp) -> AppRunState? {
        runStateCalls += 1
        return unreadable ? nil : (states[app.id] ?? AppRunState(instances: []))
    }

    func requestQuit(_ instance: AppInstance) -> Bool {
        quits.append(instance); log.append("quit")
        onQuit(instance)
        return quitResult
    }

    func forceQuit(_ instance: AppInstance) -> Bool {
        forces.append(instance); log.append("force")
        onForce(instance)
        return forceResult
    }

    func activate(_ instance: AppInstance) { activations.append(instance) }
}

/// A clock the flow's `sleep` advances, so 5 seconds of waiting takes no time.
@MainActor final class FakeClock {
    private(set) var current = Date(timeIntervalSince1970: 1_000_000)
    private(set) var ticks = 0
    var onTick: (Int) -> Void = { _ in }

    func now() -> Date { current }
    func sleep(_ d: Duration) async throws {
        let (s, a) = d.components
        current.addTimeInterval(Double(s) + Double(a) / 1e18)
        ticks += 1
        onTick(ticks)
        await Task.yield()
    }
}

/// Collects the quit lines the model writes; `failRequestedForce` makes the force `requested` line throw.
final class AuditRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _records: [AppQuitAuditRecord] = []
    var failRequestedForce = false
    var onRecord: @Sendable (AppQuitAuditRecord) -> Void = { _ in }
    struct Boom: Error {}

    var records: [AppQuitAuditRecord] { lock.withLock { _records } }
    var write: UninstallerModel.QuitAudit {
        { [self] r in
            if failRequestedForce, r.mode == "force", r.phase == "requested" { throw Boom() }
            lock.withLock { _records.append(r) }
            onRecord(r)
        }
    }
}
