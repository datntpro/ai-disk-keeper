import DiskKeeperCore
import Foundation

/// Every user-visible string of the Cleanup History screen.
enum HistoryCopy {
    static var lifetime: String { loc("history.lifetime", "Lifetime reclaimed") }
    static func items(_ n: Int) -> String { loc("history.items", "\(n) items") }
    static func entriesUnreadable(_ n: Int) -> String { loc("history.unreadable", "\(n) entries couldn't be shown (damaged, or from a newer version)") }
    static var truncated: String { loc("history.truncated", "Only the most recent part of a very large log is shown.") }
    static var reclaimed: String { loc("history.reclaimed", "Reclaimed") }
    static var skipped: String { loc("history.skipped", "Skipped") }
    static var failed: String { loc("history.failed", "Failed") }
    static var quitApp: String { loc("history.quitApp", "Quit app") }
    static var exportCSV: String { loc("history.exportCSV", "Export CSV…") }
    static var revealLog: String { loc("history.revealLog", "Show log in Finder") }
    static var revealInTrash: String { loc("history.revealInTrash", "Reveal in Trash") }
    static var notInTrash: String { loc("history.notInTrash", "No longer in the Trash") }
    static var emptyTitle: String { loc("history.empty.title", "No cleanups yet") }
    static var emptyMessage: String { loc("history.empty.message", "Every cleanup is recorded here, so you can always see what was removed and when.") }
    static var selectRun: String { loc("history.selectRun", "Select a run to see its items.") }
    static var colPath: String { loc("history.col.path", "Path") }
    static var colSize: String { loc("history.col.size", "Size") }
    static var colResult: String { loc("history.col.result", "Result") }
    static var colReason: String { loc("history.col.reason", "Details") }
    static var loadFailedTitle: String { loc("history.loadFailed.title", "Couldn't read the history") }
    static var exportFailed: String { loc("history.exportFailed", "Couldn't export the history") }
    static var csvName: String { loc("history.csvName", "cleanup-history") }
    static func failedCount(_ n: Int) -> String { "\(failed): \(Formatting.count(n))" }
    static var colActions: String { loc("history.col.actions", "Actions") }
    static func result(_ raw: String) -> String {
        switch raw {
        case "trashed": loc("history.result.trashed", "Moved to Trash")
        case "deleted": loc("history.result.deleted", "Deleted")
        case "ran": loc("history.result.ran", "Removed by its tool")
        case "skipped": skipped
        case "failed": failed
        case "intent": loc("history.result.intent", "Started, no result recorded")
        default: raw
        }
    }
    static func run(_ run: AuditRun) -> String {
        switch run.kind {
        case .appQuit: quitApp
        case .processControl: ProcessControlCopy.historyRun
        case .cleanup: items(run.items)
        }
    }
}
