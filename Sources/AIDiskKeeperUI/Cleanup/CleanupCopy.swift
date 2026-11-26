import DiskKeeperCore
import Foundation

/// All user-facing strings of the cleanup flow. Every string has a stable key and an English default, so a
/// String Catalog (en + vi) can be added without touching the views.
public enum CleanupCopy {
    public static var reviewTitle: String { loc("cleanup.review.title", "Review cleanup") }
    public static var reviewSubtitle: String {
        loc("cleanup.review.subtitle", "These items will be moved to the Trash. You can put them back from the Trash until you empty it.")
    }
    public static var footerNote: String {
        loc("cleanup.review.footer", "Disk space is freed when you empty the Trash. Every action is recorded in the audit log.")
    }
    public static var expiredNotice: String {
        loc("cleanup.review.expired", "The preview was more than 15 minutes old, so it was refreshed. Check it again.")
    }
    public static var keepHelp: String { loc("cleanup.select.keepHelp", "Keep items can't be cleaned") }
    public static var reportOnlyHelp: String { loc("cleanup.select.reportOnlyHelp", "No cleanup action for this item") }
    public static var reviewHint: String {
        loc("cleanup.select.reviewHint", "Review item: check the explanation before selecting")
    }
    public static var auditWarning: String {
        loc("cleanup.result.auditWarning", "Cleanup stopped early because the audit log couldn't be written. Items above were not touched.")
    }

    // Buttons and labels
    public static var reviewButton: String { loc("cleanup.toolbar.review", "Review cleanup…") }
    public static var cancel: String { loc("cleanup.action.cancel", "Cancel") }
    public static var stop: String { loc("cleanup.action.stop", "Stop") }
    public static var recheck: String { loc("cleanup.action.recheck", "Re-check") }
    public static var done: String { loc("cleanup.action.done", "Done") }
    public static var openTrash: String { loc("cleanup.action.openTrash", "Open Trash") }
    public static var showAuditLog: String { loc("cleanup.action.showAuditLog", "Show audit log") }
    public static var deselectAll: String { loc("cleanup.action.deselectAll", "Deselect all") }
    public static var skippedHeading: String { loc("cleanup.result.skipped", "Skipped") }
    public static var failedHeading: String { loc("cleanup.result.failed", "Failed") }
    public static var notAttemptedHeading: String { loc("cleanup.result.notAttempted", "Not attempted") }
    public static var stoppedByUser: String { loc("cleanup.result.stoppedByUser", "Stopped before these items") }
    public static var stoppedByAudit: String {
        loc("cleanup.result.stoppedByAudit", "Stopped because the audit log couldn't be written")
    }

    private static func bytes(_ n: Int64) -> String { Formatting.bytes(n) }

    public static func selectItem(_ name: String) -> String {
        loc("cleanup.select.item", "Select \(name)")
    }

    public static var selectColumn: String { loc("cleanup.select.column", "Select") }

    public static func itemAndReason(name: String, reason: String) -> String {
        loc("cleanup.select.itemAndReason", "\(name): \(reason)")
    }

    public static func itemAndTier(name: String, tier: String) -> String {
        loc("cleanup.select.itemAndTier", "\(name), \(tier)")
    }

    public static func selectedSummary(count: Int, bytes n: Int64) -> String {
        loc("cleanup.toolbar.selected", "\(count) selected · \(bytes(n))")
    }

    public static func selectAllSafeTitle(scope: String?, count: Int, bytes n: Int64) -> String {
        if let scope {
            return loc("cleanup.selectAllSafe.scoped", "Select all Safe in \(scope) (\(count) · \(bytes(n)))")
        }
        return loc("cleanup.selectAllSafe.all", "Select all Safe (\(count) · \(bytes(n)))")
    }

    public static func moveButton(_ n: Int64) -> String {
        loc("cleanup.review.move", "Move \(bytes(n)) to Trash")
    }

    public static func willMoveHeading(count: Int, bytes n: Int64) -> String {
        loc("cleanup.review.willMove", "Will be moved to Trash (\(count) · \(bytes(n)))")
    }

    public static func reviewIncluded(_ n: Int) -> String {
        n == 1
            ? loc("cleanup.review.includesOne", "Includes 1 Review item: these lose history or need a re-download.")
            : loc("cleanup.review.includesMany", "Includes \(n) Review items: these lose history or need a re-download.")
    }

    public static func wontCleanHeading(_ n: Int) -> String {
        loc("cleanup.review.wontClean", "Won't be cleaned (\(n))")
    }

    public static func quitHeading(app: String, count: Int, bytes n: Int64) -> String {
        count == 1
            ? loc("cleanup.review.quitOne", "Quit \(app) to clean this item (\(bytes(n)))")
            : loc("cleanup.review.quitMany", "Quit \(app) to clean these \(count) items (\(bytes(n)))")
    }

    public static func progress(done: Int, total: Int) -> String {
        loc("cleanup.progress.title", "Moving to Trash… \(done) of \(total)")
    }

    public static func moved(count: Int, bytes n: Int64) -> String {
        count == 1
            ? loc("cleanup.result.movedOne", "Moved 1 item to the Trash (up to \(bytes(n))).")
            : loc("cleanup.result.movedMany", "Moved \(count) items to the Trash (up to \(bytes(n))).")
    }

    public static func sectionHeading(_ title: String, count: Int) -> String {
        loc("cleanup.result.section", "\(title) (\(count))")
    }

    public static func auditOpenFailed(_ msg: String) -> String {
        loc("cleanup.error.auditUnavailable", "Cleanup didn't start: the audit log couldn't be opened (\(msg)). Nothing was changed.")
    }

    public static func internalError(_ detail: String) -> String {
        loc("cleanup.error.internal", "Internal error (\(detail)). Nothing was changed. Please rescan.")
    }

    public static func genericFailure(_ detail: String) -> String {
        loc("cleanup.error.generic", "Cleanup failed: \(detail)")
    }

    public static func unavailable(_ detail: String) -> String {
        loc("cleanup.error.unavailable", "Cleanup unavailable: \(detail)")
    }

    /// One sentence per blocker. Wraps the engine's message; app-running gets friendlier wording.
    public static func sentence(for blocker: CleanupBlocker, appName: (String) -> String = AppNameResolver.name) -> String {
        switch blocker {
        case .appRunning(let id):
            loc("cleanup.blocker.appRunning", "\(appName(id)) is running. Quit it, then press Re-check.")
        case .appStateUnknown(let id):
            loc("cleanup.blocker.appUnknown", "Couldn't tell whether \(appName(id)) is running, so this item was left alone.")
        case .keepTier: loc("cleanup.blocker.keepTier", "Marked Keep: this is never cleaned.")
        case .notActionable: loc("cleanup.blocker.notActionable", "Report only: there is no cleanup action for this item.")
        case .methodNotSupported(let m): loc("cleanup.blocker.methodNotSupported", "Cleanup method '\(m)' is not supported yet.")
        case .protectedPath(let reason, _, let pattern, let whyID): CoreCopy.denial(reason: reason, pattern: pattern, whyID: whyID)
        case .missing: loc("cleanup.blocker.missing", "The item no longer exists.")
        case .isSymlink: loc("cleanup.blocker.isSymlink", "The item is now a symbolic link.")
        case .notOwnedByUser: loc("cleanup.blocker.notOwned", "The item is not owned by you.")
        case .symlinkInParentChain(let p): loc("cleanup.blocker.parentSymlink", "A parent folder is a symbolic link (resolves to \(p)).")
        case .identityChanged: loc("cleanup.blocker.identityChanged", "The item was replaced after it was scanned.")
        case .changedSinceScan: loc("cleanup.blocker.changed", "The item changed after it was scanned. Rescan to review it again.")
        case .nestedInAnotherItem: loc("cleanup.blocker.nested", "The item overlaps another selected item.")
        case .duplicate: loc("cleanup.blocker.duplicate", "The item was selected more than once.")
        case .permanentDeleteDisabled: loc("cleanup.blocker.permanentOff", "Permanent delete is turned off.")
        case .sizingFailed(let e): loc("cleanup.blocker.sizing", "Could not re-measure the item: \(e)")
        case .wouldRemoveAllCopies:
            loc("cleanup.blocker.allCopies", "Every copy in this duplicate group is selected. Keep at least one.")
        case .survivorChanged:
            loc("cleanup.blocker.survivorChanged", "The copy you're keeping changed or disappeared. Rescan before deleting this duplicate.")
        case .duplicateGroupUnknown:
            loc("cleanup.blocker.groupUnknown", "Duplicate details are missing. Rescan and review the group.")
        }
    }
}
