import DiskKeeperCore
import Foundation

/// Every user-visible string of the Uninstaller screen. Core's English `explanation`s are not shown.
enum UninstallerCopy {
    static var title: String { loc("apps.title", "Uninstaller") }
    static func subtitle(apps: String, unused: String) -> String {
        loc("apps.subtitle", "\(apps) apps · \(unused) unused for 90+ days")
    }
    static var tabApps: String { loc("apps.tab.apps", "Apps") }
    static func tabOrphans(_ count: String) -> String { loc("apps.tab.orphans", "Orphaned leftovers \(count)") }
    static var search: String { loc("apps.search", "Search apps") }
    static var loading: String { loc("apps.loading", "Reading your apps…") }
    static var failed: String { loc("apps.failed", "Couldn't list your apps. Nothing was changed.") }
    static var failedTitle: String { loc("apps.failed.title", "Couldn't read your apps") }
    static var retry: String { loc("apps.retry", "Try again") }
    static var emptyTitle: String { loc("apps.empty.title", "No apps found") }
    static var emptyMessage: String { loc("apps.empty.message", "No apps were found in Applications or ~/Applications.") }
    static func noMatch(_ query: String) -> String { loc("apps.noMatch", "No apps match “\(query)”") }
    static var clearSearch: String { loc("apps.search.clear", "Clear search") }
    static var selectApp: String { loc("apps.select", "Select an app to see what it leaves behind.") }

    // Rows
    static func lastOpened(_ when: String) -> String { loc("apps.lastOpened", "last opened \(when)") }
    static var neverOpened: String { loc("apps.neverOpened", "never opened") }
    static var runningNow: String { loc("apps.runningNow", "running now") }
    static var apple: String { loc("apps.apple", "Apple system app · can't be removed") }
    static func appStore(_ when: String) -> String { loc("apps.appStore", "App Store · \(when)") }
    static var allUsers: String { loc("apps.allUsers", "Installed for all users") }
    static func a11yApp(_ name: String, _ caption: String, _ size: String) -> String {
        loc("apps.a11y.app", "\(name), \(caption), \(size)")
    }
    static func a11yRelated(_ name: String, _ match: String, _ size: String, _ state: String) -> String {
        loc("apps.a11y.related", "\(name), \(match), \(size), \(state)")
    }
    static var ticked: String { loc("apps.a11y.ticked", "selected") }
    static var unticked: String { loc("apps.a11y.unticked", "not selected") }

    // Detail
    static var sourceAppStore: String { loc("apps.source.appStore", "Mac App Store") }
    static func sourceDeveloperID(_ team: String) -> String { loc("apps.source.developerID", "Developer ID: \(team)") }
    static var sourceUnsigned: String { loc("apps.source.unsigned", "Unsigned") }
    static var sourceApple: String { loc("apps.source.apple", "Apple") }
    static func total(_ app: String, _ related: String) -> String { loc("apps.total", "app \(app) + \(related) related items") }
    static var sectionBundle: String { loc("apps.section.bundle", "App bundle") }
    static var sectionRelated: String { loc("apps.section.related", "Related files in your Library") }
    static var sectionShared: String { loc("apps.section.shared", "May be shared") }
    static var noRelated: String { loc("apps.related.none", "No related files found in your Library.") }
    static var matchExact: String { loc("apps.match.exact", "bundle id") }
    static var matchLaunchAgent: String { loc("apps.match.launchAgent", "launch agent") }
    static var matchName: String { loc("apps.match.name", "vendor name · may be shared") }
    static func matchShared(_ owners: String) -> String { loc("apps.match.shared", "used by \(owners)") }
    static var sizeIncomplete: String { loc("apps.sizeIncomplete", "size may be incomplete") }
    static var noteTitle: String { loc("apps.note.title", "Before you uninstall") }
    static func noteBody(_ name: String) -> String {
        loc("apps.note.body", "Documents you made with \(name) are not touched. Its settings in ~/Library/Preferences stay. Everything else goes to the Trash, so you can put it back.")
    }

    // Guidance
    static var guideAppManagement: String {
        loc("apps.guide.appManagement", "Needs permission once — macOS asks you to allow AI Disk Keeper under Privacy & Security › App Management to move apps.")
    }
    static var openSettings: String { loc("apps.guide.openSettings", "Open settings") }
    static var guideAdmin: String {
        loc("apps.guide.admin", "Installed for all users. Drag it to the Trash in Finder; you may need an administrator password.")
    }
    static var reveal: String { loc("apps.guide.reveal", "Reveal in Finder") }
    static func guideRunning(_ name: String) -> String { loc("apps.guide.running", "\(name) is running. Quit it to uninstall.") }
    static func locked(_ r: InstalledApp.ViewOnlyReason) -> String {
        switch r {
        case .apple: loc("apps.guide.locked.apple", "Part of macOS or Apple software. It can't be removed here.")
        case .systemVolume: loc("apps.guide.locked.system", "Lives on the protected system volume. It can't be removed here.")
        case .symlink: loc("apps.guide.locked.symlink", "A link to an app stored elsewhere. It can't be removed here.")
        case .notTopLevel: loc("apps.guide.locked.notTopLevel", "Inside a sub-folder of Applications (a suite or vendor folder). It can't be removed here.")
        case .noBundleID: loc("apps.guide.locked.noBundleID", "This app has no bundle identifier. It can't be removed here.")
        case .notOwnedByUser: guideAdmin
        }
    }

    // Action bar
    static func barSummary(_ related: String) -> String { loc("apps.bar.summary", "app + \(related) related items") }
    static var reset: String { loc("apps.action.reset", "Reset app only") }
    static var resetHelp: String { loc("apps.action.reset.help", "Moves its caches and saved state to the Trash and keeps the app.") }
    static var uninstall: String { loc("apps.action.uninstall", "Uninstall…") }
    static var disabledRunning: String { loc("apps.action.disabled.running", "Quit the app first") }

    // Orphans
    static var orphansExplain: String {
        loc("apps.orphans.explain", "Left behind by an app that no longer seems to be installed anywhere on this Mac, and untouched for over 30 days.")
    }
    static var orphansNone: String {
        loc("apps.orphans.none", "No orphaned leftovers — every Library folder belongs to an installed app.")
    }
    static var orphansReview: String { loc("apps.orphans.review", "Review cleanup…") }
    static func orphansSelected(_ n: String) -> String { loc("apps.orphans.selected", "\(n) selected") }
    static func orphanModified(_ when: String) -> String { loc("apps.orphans.modified", "last modified \(when)") }
}
