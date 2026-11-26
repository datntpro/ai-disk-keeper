import DiskKeeperCore
import Foundation

/// Why Uninstall isn't (or wasn't) simply possible, and what to tell the user.
enum UninstallGuidance: Equatable {
    /// macOS blocked the move (`needsAppManagementPermission`): allow us under Privacy & Security › App Management.
    case appManagement(bundleID: String)
    /// Installed for all users: remove it in Finder.
    case requiresAdmin(bundleID: String)
    /// Running; `quit` is where a Quit press is, `background` lists "name (pid)" of processes we never signal.
    case running(name: String, quit: QuitFlowState? = nil, background: [String] = [], otherUser: Bool = false, canQuit: Bool = false)
    /// The process list couldn't be read: nothing is quit and Uninstall stays off.
    case runningUnknown(name: String)
    /// This is AI Disk Keeper itself.
    case selfApp
    /// The app was running and has just quit.
    case quitDone(name: String)
    case locked(InstalledApp.ViewOnlyReason)

    var needsSettingsLink: Bool { if case .appManagement = self { true } else { false } }
    var needsReveal: Bool {
        switch self {
        case .requiresAdmin, .locked(.notOwnedByUser): true
        default: false
        }
    }

    /// What the model knows about a running app.
    struct RunInfo: Equatable {
        var unknown = false
        var selfApp = false
        var quit: QuitFlowState?
        var canQuit = false
        var background: [String] = []
        var otherUser = false
    }

    /// The guidance the screen shows for `app`: what stops it now beats what happened last time.
    static func resolve(app: InstalledApp, availability: UninstallAvailability, last: UninstallGuidance?,
                        run: RunInfo? = nil, quit: QuitFlowState? = nil) -> UninstallGuidance? {
        switch availability {
        case .viewOnly(let reason): return .locked(reason)
        case .running:
            guard let run else { return .running(name: app.name) }
            if run.selfApp { return .selfApp }
            if run.unknown { return .runningUnknown(name: app.name) }
            return .running(name: app.name, quit: run.quit, background: run.background, otherUser: run.otherUser, canQuit: run.canQuit)
        case .available:
            if quit == .done { return .quitDone(name: app.name) }
            switch last {
            case .appManagement(let id)? where id == app.bundleID: return last
            case .requiresAdmin(let id)? where id == app.bundleID: return last
            default: return nil
            }
        }
    }

    /// Looks for a refusal of the app bundle in a finished run.
    static func from(report: CleanupReport, bundleID: String) -> UninstallGuidance? {
        for result in report.results {
            guard case .skipped(let blockers) = result.outcome else { continue }
            for b in blockers {
                switch b {
                case .needsAppManagementPermission(let id) where id == bundleID: return .appManagement(bundleID: id)
                case .requiresAdmin(let id) where id == bundleID: return .requiresAdmin(bundleID: id)
                default: continue
                }
            }
        }
        return nil
    }
}

enum UninstallAvailability: Equatable {
    case available, running
    case viewOnly(InstalledApp.ViewOnlyReason)
}
