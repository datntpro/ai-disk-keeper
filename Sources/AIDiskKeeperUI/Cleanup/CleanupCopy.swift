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

    // T45: review sheet and results restyle
    public static func titleBytes(_ n: Int64) -> String { loc("cleanup.review.titleBytes", "Move \(bytes(n)) to the Trash?") }
    public static var dryRun: String {
        loc("cleanup.review.dryRun", "This is a dry run: nothing has changed yet. Each item is checked again right before it moves.")
    }
    public static var trioWillMove: String { loc("cleanup.trio.willMove", "Will move") }
    public static func trioItems(_ n: Int) -> String { loc("cleanup.trio.items", "\(Formatting.count(n)) items") }
    public static var trioFrees: String { loc("cleanup.trio.frees", "Frees after emptying Trash") }
    public static var trioSkipped: String { loc("cleanup.trio.skipped", "Skipped") }
    public static var rowThenPrune: String { loc("cleanup.row.thenPrune", "then git worktree prune") }
    public static var rowTickedByYou: String { loc("cleanup.row.tickedByYou", "ticked by you") }
    public static func rowMoreReasons(_ n: Int) -> String { loc("cleanup.row.moreReasons", "+\(Formatting.count(n)) more") }
    public static func rowQuitFirst(app: String) -> String { loc("cleanup.row.quitFirst", "\(app) is running — quit it first") }
    /// "Plan valid %@" split around the placeholder, so the countdown can be a live `Text(timerInterval:)`.
    public static var planValidParts: (before: String, after: String) {
        let marker = "\u{1F}"
        let s = loc("cleanup.planValid", "Plan valid \(marker)")
        let parts = s.components(separatedBy: marker)
        return (parts.first ?? s, parts.count > 1 ? parts[1] : "")
    }
    public static func confirm(_ n: Int64) -> String { loc("cleanup.confirm", "Move \(bytes(n)) to Trash") }
    public static var several: String { loc("cleanup.several", "Several sources") }
    public static var resultComplete: String { loc("cleanup.result.complete", "Cleanup complete") }
    public static var resultStopped: String { loc("cleanup.result.stopped", "Cleanup stopped") }
    public static var resultProblems: String { loc("cleanup.result.problems", "Cleanup finished with problems") }
    public static func resultSummary(items: Int, errors: Int, skipped: Int) -> String {
        loc("cleanup.result.summary",
            "moved to the Trash · \(Formatting.count(items)) items · \(Formatting.count(errors)) errors · \(Formatting.count(skipped)) skipped")
    }
    public static func resultBefore(_ n: Int64) -> String { loc("cleanup.result.before", "Before · \(bytes(n)) free") }
    public static func resultAfter(_ n: Int64) -> String {
        loc("cleanup.result.after", "After you empty the Trash · \(bytes(n)) free")
    }
    public static var outcomeTrashed: String { loc("cleanup.outcome.trashed", "Trashed") }
    public static var outcomePruned: String { loc("cleanup.outcome.pruned", "Trashed · worktree pruned") }
    public static func outcomeSkipped(_ why: String) -> String { loc("cleanup.outcome.skipped", "Skipped — \(why)") }
    public static func outcomeFailed(_ why: String) -> String { loc("cleanup.outcome.failed", "Failed — \(why)") }
    public static var nextRescan: String { loc("cleanup.next.rescan", "Re-scan") }
    public static func nextQuit(app: String) -> String { loc("cleanup.next.quit", "Quit \(app), then review again") }
    public static var nextOpenSettings: String { loc("cleanup.next.openSettings", "Open settings") }
    public static var nextReveal: String { loc("cleanup.next.reveal", "Reveal in Finder") }
    public static var nextProtected: String { loc("cleanup.next.protected", "No action needed — this item is protected") }
    public static var nextTryLater: String { loc("cleanup.next.tryLater", "Try again later. Nothing else was changed.") }
    public static var auditPaused: String {
        loc("cleanup.audit.paused", "Cleanup paused: audit log unavailable. Nothing more was moved.")
    }
    public static var auditRevealFolder: String { loc("cleanup.audit.revealFolder", "Reveal folder") }
    public static func rowA11y(tier: String, name: String, reason: String, size: String) -> String {
        loc("cleanup.a11y.row", "\(tier), \(name), \(reason), \(size)")
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
            loc("cleanup.blocker.allCopies", "No copy of this duplicate group would be left. Keep at least one.")
        case .survivorChanged:
            loc("cleanup.blocker.survivorChanged", "The copy you're keeping changed or disappeared. Rescan before deleting this duplicate.")
        case .duplicateGroupUnknown:
            loc("cleanup.blocker.groupUnknown", "Duplicate details are missing. Rescan and review the group.")
        case .appBundleRefused(let refusal): appRefusal(refusal)
        case .requiresAdmin:
            loc("cleanup.blocker.app.requiresAdmin", "Installed for all users. Drag it to the Trash in Finder (you may need an administrator password).")
        case .needsAppManagementPermission:
            loc("cleanup.blocker.app.needsAppManagement", "macOS blocked this. Allow AI Disk Keeper in System Settings › Privacy & Security › App Management, then try again.")
        }
    }

    static func appRefusal(_ r: AppBundleRefusal) -> String {
        switch r {
        case .invalidPath: loc("cleanup.blocker.app.invalidPath", "This app's location isn't valid, so it was left alone.")
        case .notTopLevel: loc("cleanup.blocker.app.notTopLevel", "Only apps directly in Applications can be removed here.")
        case .insideBundle: loc("cleanup.blocker.app.insideBundle", "This is inside another app, so it can't be removed on its own.")
        case .rootItself: loc("cleanup.blocker.app.rootItself", "The Applications folder itself can't be removed.")
        case .notAnAppBundle: loc("cleanup.blocker.app.notAnAppBundle", "This isn't a valid app, so it was left alone.")
        case .symlink: loc("cleanup.blocker.app.symlink", "This is a link to an app stored elsewhere.")
        case .resolvedElsewhere: loc("cleanup.blocker.app.resolvedElsewhere", "This app's location points somewhere else, so it was left alone.")
        case .appleOrSystem: loc("cleanup.blocker.app.appleOrSystem", "Part of macOS or Apple software. It can't be removed.")
        case .signatureUnreadable: loc("cleanup.blocker.app.signatureUnreadable", "The app's signature couldn't be read, so it was left alone.")
        case .bundleIDMismatch: loc("cleanup.blocker.app.bundleIDMismatch", "The app was replaced after the scan. Scan again.")
        case .missingInfoPlist: loc("cleanup.blocker.app.missingInfoPlist", "The app's information file is missing or unreadable, so it was left alone.")
        case .permanentDelete: loc("cleanup.blocker.app.permanentDelete", "Apps can only be moved to the Trash.")
        case .notApplicationMethod: loc("cleanup.blocker.app.notApplicationMethod", "App removal isn't available here.")
        }
    }
}
