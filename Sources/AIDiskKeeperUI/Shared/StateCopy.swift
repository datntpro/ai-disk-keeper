import Foundation

/// Every empty / permission / error state's wording in one file, so the copy review is one read.
/// Rules: say what is true, say what to do next, and for errors always say what did NOT happen.
enum StateCopy {
    // First run
    static var firstRunTitle: String { loc("state.firstRun.title", "See what your AI tools left behind") }
    static var firstRunBody: String { loc("state.firstRun.body", "A read-only scan of your home folder. Nothing is deleted until you review it.") }
    static var firstRunStart: String { loc("state.firstRun.start", "Start Care Scan") }
    static var firstRunWhat: String { loc("state.firstRun.what", "What gets scanned?") }
    static var firstRunWhatBody: String {
        loc("state.firstRun.whatBody", "AI tool folders (~/.claude, ~/.cursor…), agent worktrees, model caches, system and developer caches, large and old files, duplicates in Home, and app leftovers in ~/Library. Folder sizes only; file contents are read only to compare duplicates.")
    }

    // Full Disk Access (optional)
    static func fdaTitle(_ count: Int) -> String { loc("state.fda.title", "\(count) folders need Full Disk Access") }
    static var fdaBody: String { loc("state.fda.body", "Mail downloads, Safari caches and other apps' containers are hidden by macOS. Everything else still works without it.") }
    static var fdaOpen: String { loc("state.fda.open", "Open Privacy settings") }
    static var fdaNotNow: String { loc("state.fda.notNow", "Not now") }

    // Empty
    static var emptyNothing: String { loc("state.empty.nothing", "Nothing to reclaim right now") }
    static func emptyModule(_ name: String) -> String { loc("state.empty.module", "No \(name) data found") }
    static var notScanned: String { loc("state.notScanned", "Not scanned yet") }
    static var noWarnings: String { loc("state.noWarnings", "No warnings") }
    static var allBlocked: String { loc("state.cleanup.allBlocked", "Nothing in this selection can be cleaned") }

    // Filtered empty
    static func filteredTitle(_ query: String) -> String { loc("state.filtered.title", "Nothing matches “\(query)”") }
    static var filteredBody: String { loc("state.filtered.body", "Try another name, or show Keep items too.") }
    static var filteredTiersTitle: String { loc("state.filtered.tiers.title", "Every match is hidden by the tier filter") }
    static var filteredTiersBody: String { loc("state.filtered.tiers.body", "Turn the hidden tiers back on to see them.") }
    static var filteredShowAll: String { loc("state.filtered.tiers.show", "Show all tiers") }
    static var filteredClear: String { loc("state.filtered.clear", "Clear search") }

    // Partial error
    static func partialTitle(_ count: Int) -> String { loc("state.partial.title", "Scan finished with \(count) warnings") }
    static var partialBody: String { loc("state.partial.body", "Some folders couldn't be read. Results from every other module are complete.") }
    static var partialShow: String { loc("state.partial.show", "Show warnings") }

    // Blocking errors: each says what did not happen.
    static var errorScan: String { loc("state.error.scan", "Couldn't start the scan. Nothing was changed.") }
    static var errorIndex: String { loc("state.error.index", "Couldn't map the disk. Nothing was changed.") }
    static var errorStartup: String { loc("state.error.startup", "Couldn't read launch agents. Nothing was changed.") }
    static var errorCleanupTitle: String { loc("state.error.cleanup.title", "Cleanup paused. Nothing was moved.") }
    static var errorAuditTitle: String { loc("state.error.audit.title", "Cleanup paused: audit log unavailable") }
    static var errorAuditBody: String {
        loc("state.error.audit.body", "We only act when every action can be recorded. Nothing was moved. Check free space in ~/Library/Application Support.")
    }
    static var retry: String { loc("state.retry", "Try again") }
    static var revealFolder: String { loc("state.revealFolder", "Reveal folder") }

    // Accessibility
    static func ring(percent: String, free: String) -> String { loc("a11y.ring", "\(percent) percent used, \(free) free") }
}
