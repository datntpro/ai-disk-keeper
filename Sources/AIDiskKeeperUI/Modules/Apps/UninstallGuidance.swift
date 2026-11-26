import DiskKeeperCore
import Foundation

/// Why Uninstall isn't (or wasn't) simply possible, and what to tell the user.
enum UninstallGuidance: Equatable {
    /// macOS blocked the move (`needsAppManagementPermission`): allow us under Privacy & Security › App Management.
    case appManagement(bundleID: String)
    /// Installed for all users: remove it in Finder.
    case requiresAdmin(bundleID: String)
    case running(name: String)
    case locked(InstalledApp.ViewOnlyReason)

    var needsSettingsLink: Bool { if case .appManagement = self { true } else { false } }
    var needsReveal: Bool {
        switch self {
        case .requiresAdmin, .locked(.notOwnedByUser): true
        default: false
        }
    }

    /// The guidance the screen shows for `app`: what stops it now beats what happened last time.
    static func resolve(app: InstalledApp, availability: UninstallAvailability, last: UninstallGuidance?) -> UninstallGuidance? {
        switch availability {
        case .viewOnly(let reason): return .locked(reason)
        case .running: return .running(name: app.name)
        case .available:
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
