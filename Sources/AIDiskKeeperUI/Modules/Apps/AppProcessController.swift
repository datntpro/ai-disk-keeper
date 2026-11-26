import AppKit
import DiskKeeperCore
import Foundation

/// One running piece of an app, as the Uninstaller sees it.
struct AppInstance: Hashable, Sendable {
    enum Kind: Sendable { case main, helperApp, background }
    /// Opaque handle issued by the controller. Nothing acts on a bare pid number.
    let token: UUID
    let pid: pid_t
    let kind: Kind
    /// `localizedName` ?? executable file name.
    let name: String
    let bundleID: String?
    /// Bundle path (main / helper app) or executable path (background).
    let location: String?
    /// `nil` = couldn't tell; treated as "not ours" (refuse).
    let ownedByCurrentUser: Bool?
}

struct AppRunState: Equatable, Sendable {
    /// Empty = not running.
    let instances: [AppInstance]
    var isRunning: Bool { !instances.isEmpty }
}

/// Everything the Uninstaller needs to know about, and do to, running processes. Tests inject a fake;
/// only `WorkspaceAppProcessController` below talks to the real system.
@MainActor protocol AppProcessControlling: AnyObject {
    /// One process walk for all apps (list badges). `nil` = couldn't read the process list (fail closed).
    func runningAppIDs(for apps: [InstalledApp]) -> Set<InstalledApp.ID>?
    /// Full detail for one app. `nil` = couldn't read (fail closed).
    func runState(for app: InstalledApp) -> AppRunState?
    /// Graceful quit, like ⌘Q. `false` = refused, not ours, or already gone.
    func requestQuit(_ instance: AppInstance) -> Bool
    /// Force quit. Only for instances from the latest `runState` of the same app.
    func forceQuit(_ instance: AppInstance) -> Bool
    /// Brings the app forward so the user can answer its save dialog.
    func activate(_ instance: AppInstance)
}

/// The live controller. The ONLY place that may send a quit request, force quit or activate another app.
/// It keeps the `NSRunningApplication` objects of the latest `runState` per app and acts on those; it never
/// looks a process up by pid number at act time (no pid-reuse hazard) and never signals anything else.
@MainActor final class WorkspaceAppProcessController: AppProcessControlling {
    private var held: [InstalledApp.ID: [UUID: NSRunningApplication]] = [:]
    private let selfPath: String?

    init(selfBundlePath: String? = Bundle.main.bundleURL.path) { selfPath = selfBundlePath }

    // MARK: Reading

    func runningAppIDs(for apps: [InstalledApp]) -> Set<InstalledApp.ID>? {
        guard let snap = LiveProcessScanner.snapshot() else { return nil }
        let live = NSWorkspace.shared.runningApplications.filter { !$0.isTerminated }
        let bundleIDs = Set(live.compactMap(\.bundleIdentifier))
        let roots: [String] = live.flatMap { [Self.resolved($0.bundleURL), Self.resolved($0.executableURL)].compactMap { $0 } }
        var ids: Set<InstalledApp.ID> = []
        for app in apps {
            if bundleIDs.contains(app.bundleID) { ids.insert(app.id); continue }
            let root = Self.resolved(URL(fileURLWithPath: app.path)) ?? ""
            if !root.isEmpty, roots.contains(where: { $0 == root || $0.hasPrefix(root + "/") }) { ids.insert(app.id); continue }
            if !LiveProcessScanner.entries(insideBundleAt: app.path, in: snap).isEmpty { ids.insert(app.id) }
        }
        return ids
    }

    func runState(for app: InstalledApp) -> AppRunState? {
        guard let snap = LiveProcessScanner.snapshot() else { return nil }
        let uids = Dictionary(snap.map { ($0.pid, $0.uid) }, uniquingKeysWith: { a, _ in a })
        let live = NSWorkspace.shared.runningApplications.filter { !$0.isTerminated }
        let root = Self.resolved(URL(fileURLWithPath: app.path)) ?? ""
        func inside(_ url: URL?) -> Bool {
            guard let p = Self.resolved(url), !root.isEmpty else { return false }
            return p == root || p.hasPrefix(root + "/")
        }
        var table: [UUID: NSRunningApplication] = [:]
        var instances: [AppInstance] = []
        var seen: Set<pid_t> = []
        func add(_ r: NSRunningApplication, _ kind: AppInstance.Kind) {
            guard seen.insert(r.processIdentifier).inserted else { return }
            let owner = uids[r.processIdentifier] ?? nil
            let token = UUID()
            table[token] = r
            instances.append(AppInstance(token: token, pid: r.processIdentifier, kind: kind,
                                         name: r.localizedName ?? r.executableURL?.lastPathComponent ?? app.name,
                                         bundleID: r.bundleIdentifier, location: r.bundleURL?.path,
                                         ownedByCurrentUser: owner.map { $0 == getuid() }))
        }
        for r in live where r.bundleIdentifier == app.bundleID { add(r, .main) }
        for r in live where inside(r.bundleURL) || inside(r.executableURL) { add(r, .helperApp) }
        for e in LiveProcessScanner.entries(insideBundleAt: app.path, in: snap) where !seen.contains(e.pid) {
            seen.insert(e.pid)
            instances.append(AppInstance(token: UUID(), pid: e.pid, kind: .background,
                                         name: (e.path as NSString).lastPathComponent, bundleID: nil, location: e.path,
                                         ownedByCurrentUser: e.uid.map { $0 == getuid() }))
        }
        held[app.id] = table
        return AppRunState(instances: instances)
    }

    private static func resolved(_ url: URL?) -> String? {
        url?.resolvingSymlinksInPath().path.lowercased()
    }

    // MARK: Acting

    func requestQuit(_ instance: AppInstance) -> Bool {
        guard let app = allowed(instance) else { return false }
        return app.terminate()
    }

    func forceQuit(_ instance: AppInstance) -> Bool {
        guard let app = allowed(instance) else { return false }
        return app.forceTerminate()
    }

    func activate(_ instance: AppInstance) {
        guard instance.kind != .background, let app = holder(of: instance), !app.isTerminated else { return }
        app.activate()
    }

    private func holder(of instance: AppInstance) -> NSRunningApplication? {
        for table in held.values { if let app = table[instance.token] { return app } }
        return nil
    }

    /// The held process, only if it is still the one we described and the policy still allows quitting it.
    private func allowed(_ instance: AppInstance) -> NSRunningApplication? {
        guard instance.kind != .background, let app = holder(of: instance), !app.isTerminated,
              app.processIdentifier == instance.pid else { return nil }
        let uid = getuid()
        let owner: uid_t? = instance.ownedByCurrentUser.map { $0 ? uid : uid &+ 1 }
        guard AppQuitPolicy.refusal(pid: instance.pid, bundleID: instance.bundleID, ownerUID: owner, currentUID: uid,
                                    selfPID: getpid(), location: instance.location, selfBundlePath: selfPath) == nil else { return nil }
        return app
    }
}
