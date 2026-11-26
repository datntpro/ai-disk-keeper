import Foundation

/// Every string of the Overview and the Care Scan hero. Numbers and bytes arrive already formatted.
enum OverviewCopy {
    static var title: String { loc("overview.title", "Overview") }
    static func lastScan(_ when: String) -> String { loc("overview.lastScanRO", "Last scan \(when) · read-only") }

    static var eyebrowBefore: String { loc("care.eyebrow.before", "Care Scan") }
    static var eyebrowScanning: String { loc("care.eyebrow.scanning", "Scanning — nothing is changed") }
    static var eyebrowResults: String { loc("care.eyebrow.results", "Ready to reclaim safely") }

    static func free(_ bytes: String) -> String { loc("care.free", "\(bytes) free") }
    static func found(_ bytes: String) -> String { loc("care.found", "\(bytes) found") }

    static var subtitleBefore: String {
        loc("care.sub.before", "One read-only scan across AI tools, worktrees, models, system junk, large files, duplicates and apps. You review everything before anything moves to the Trash.")
    }
    static func subtitleScanning(_ what: String) -> String { loc("care.sub.scanning", "Looking at \(what)… You can stop at any time.") }
    static func subtitleResults(safe: String, review: String, keep: String) -> String {
        loc("care.sub.results", "\(safe) is Safe to move to the Trash now. \(review) more needs your review, and \(keep) is kept because it has uncommitted work or was used recently.")
    }

    static var buttonScan: String { loc("care.button.scan", "Scan") }
    static var buttonStop: String { loc("care.button.stop", "Stop") }
    static var buttonReview: String { loc("care.button.review", "Review") }
    static var a11yScan: String { loc("care.button.a11y.scan", "Scan") }
    static var a11yStop: String { loc("care.button.a11y.stop", "Stop scan") }
    static func a11yReview(_ bytes: String) -> String { loc("care.button.a11y.review", "Review \(bytes)") }

    static var cleanSafe: String { loc("care.cleanSafe", "Clean Safe only…") }
    static func growthUp(_ bytes: String) -> String { loc("care.growth.up", "AI tools +\(bytes) since last scan") }
    static func growthDown(_ bytes: String) -> String { loc("care.growth.down", "AI tools \(bytes) smaller since last scan") }

    static func chipsA11y(_ list: String) -> String { loc("care.chips.a11y", "Scanning: \(list)") }
    static func chipA11y(_ name: String, _ state: String) -> String { loc("care.chip.a11y", "\(name) \(state)") }
    static var stageDone: String { loc("care.stage.done", "done") }
    static var stageRunning: String { loc("care.stage.running", "running") }
    static var stagePending: String { loc("care.stage.pending", "pending") }
    static var stageFailed: String { loc("care.stage.failed", "couldn't finish") }
    static var stageSkipped: String { loc("care.stage.skipped", "skipped") }
    static var stopped: String { loc("care.stopped", "Stopped — results are partial") }

    static var strataEverythingElse: String { loc("care.strata.everythingElse", "Everything else") }
    static var strataUsed: String { loc("care.strata.used", "Used") }
    static var modulesTitle: String { loc("care.modules.title", "Modules") }
    static var modulesCaption: String { loc("care.modules.caption", "Numbers are what each module can reclaim") }

    static func tileAITools(names: String, more: Int, items: Int) -> String {
        let head = more > 0 ? "\(names) \(loc("care.tile.moreTools", "+\(more) tools"))" : names
        return "\(head) · \(tileItems(items))"
    }
    static func tileLargeOld(_ count: Int) -> String { loc("care.tile.largeOld", "\(count) large files in your home folder") }
    static func tileDuplicates(_ groups: Int) -> String { loc("care.tile.duplicates", "\(groups) groups · clones excluded") }
    static func tileApps(_ count: Int) -> String { loc("care.tile.apps", "\(count) leftover items") }
    static var tileSystemJunk: String { loc("care.tile.systemJunk", "Caches, logs, crash reports, dev caches") }
    static func tileItems(_ count: Int) -> String { loc("care.tile.items", "\(count) items") }
    static var chipIndex: String { loc("care.chip.index", "File index") }

    static var winsTitle: String { loc("care.wins.title", "Biggest wins") }
    static var winsSeeAll: String { loc("care.wins.seeAll", "See all") }
    static func unreadable(_ count: Int) -> String { loc("overview.unreadable", "\(count) folders couldn't be read") }

    static func finishedAnnouncement(safe: String, review: String) -> String {
        loc("care.announce.finished", "Care Scan finished. \(safe) is Safe to move to the Trash; \(review) needs review.")
    }
}
