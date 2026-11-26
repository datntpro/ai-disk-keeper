import Foundation

enum HistoryCopy {
    static var title: String { loc("history.title", "Cleanup History") }
    static var lifetime: String { loc("history.lifetime", "Lifetime reclaimed") }
    static func items(_ n: Int) -> String { loc("history.items", "\(n) items") }
    static var reclaimed: String { loc("history.reclaimed", "Reclaimed") }
    static var skipped: String { loc("history.skipped", "Skipped") }
    static var failed: String { loc("history.failed", "Failed") }
    static var quitApp: String { loc("history.quitApp", "Quit app") }
    static var exportCSV: String { loc("history.exportCSV", "Export CSV…") }
    static var revealLog: String { loc("history.revealLog", "Show audit log") }
    static var revealInTrash: String { loc("history.revealInTrash", "Reveal in Trash") }
    static var notInTrash: String { loc("history.notInTrash", "No longer in the Trash") }
    static func unreadable(_ n: Int) -> String { loc("history.unreadable", "\(n) entries couldn't be read") }
    static var truncated: String { loc("history.truncated", "The log is large, so only the most recent entries are shown.") }
    static var emptyTitle: String { loc("history.empty.title", "No cleanups yet") }
    static var emptyMessage: String {
        loc("history.empty.message", "When you clean something up, each action is recorded here.")
    }
    static var loading: String { loc("history.loading", "Reading the audit log…") }
    static var failedTitle: String { loc("history.failed.title", "Couldn't read the audit log") }
    static var retry: String { loc("history.retry", "Try again") }
    static var selectRun: String { loc("history.selectRun", "Select a run to see its items.") }
    static var colPath: String { loc("history.col.path", "Path") }
    static var colSize: String { loc("history.col.size", "Size") }
    static var colResult: String { loc("history.col.result", "Result") }
    static var resultTrashed: String { loc("history.result.trashed", "Moved to Trash") }
    static var resultDeleted: String { loc("history.result.deleted", "Deleted") }
    static var resultRan: String { loc("history.result.ran", "Ran command") }
    static var resultSkipped: String { loc("history.result.skipped", "Skipped") }
    static var resultFailed: String { loc("history.result.failed", "Failed") }
    static var resultOther: String { loc("history.result.other", "Other") }
    static func runBytes(_ bytes: String) -> String { loc("history.run.bytes", "\(bytes) reclaimed") }
    static func quitResult(_ result: String) -> String { loc("history.quit.result", "Quit app: \(result)") }
    static var exportFailed: String { loc("history.export.failed", "Couldn't save the CSV file.") }
    static func a11yLifetime(_ bytes: String) -> String { loc("history.a11y.lifetime", "Lifetime reclaimed, \(bytes)") }
    static func a11yFailed(_ n: Int) -> String { loc("history.a11y.failed", "Failed: \(n)") }
    static func runSummary(_ items: String, _ bytes: String) -> String { loc("history.run.summary", "\(items) · \(bytes)") }
}
