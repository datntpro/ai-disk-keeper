import DiskKeeperCore
import Foundation

/// Fixture apps and leftovers: values only, never the real `/Applications`, Spotlight or LaunchServices.
enum UninstallFix {
    static let home = "/h"

    static func app(_ name: String, id: String? = nil, size: Int64 = 1000, lastUsed: Date? = nil,
                    reason: InstalledApp.ViewOnlyReason? = nil, source: AppSource = .developerID(teamID: "TEAM1"),
                    location: AppLocation = .userApplications) -> InstalledApp {
        InstalledApp(path: "/h/Applications/\(name).app", bundleID: id ?? "com.test.\(name.lowercased())", name: name,
                     location: location, source: source, ownerUID: 501, isSymlink: false, sizeAllocated: size,
                     sizeLogical: size, fileCount: 3, lastUsed: lastUsed, viewOnlyReason: reason)
    }

    static func leftover(_ app: InstalledApp?, _ location: String, _ name: String, rule: String = "apps.leftover.exact",
                         size: Int64 = 100, method: CleanupMethod = .trash, modified: Date? = nil) -> ScanItem {
        ScanItem(url: URL(fileURLWithPath: "/h/Library/\(location)/\(name)"), displayName: "\(name) · \(location)",
                 tool: .apps, category: .appLeftover, sizeAllocated: size, sizeLogical: size, fileCount: 1,
                 lastModified: modified, tier: .review, explanation: "x", ruleID: rule, cleanupMethod: method,
                 groupID: app.map { "app:\($0.bundleID)" })
    }

    static let slide = app("Slidecraft", size: 5000)
    static var slideItems: [ScanItem] {
        [leftover(slide, "Caches", "com.test.slidecraft", size: 300),
         leftover(slide, "Application Support", "com.test.slidecraft", size: 200),
         leftover(slide, "Saved Application State", "com.test.slidecraft.savedState", size: 50),
         leftover(slide, "LaunchAgents", "com.test.slidecraft.helper.plist", size: 1),
         leftover(slide, "Application Support", "Slidecraft", rule: "apps.leftover.name", size: 40),
         leftover(slide, "Containers", "com.test.slidecraft", method: .none)]
    }
    static let sharedItem = leftover(nil, "Logs", "Slidecraft", rule: "apps.leftover.name", size: 7)
    static var orphanItems: [ScanItem] {
        [leftover(nil, "Containers", "com.ghost.app", rule: "apps.leftover.orphan", size: 900),
         leftover(nil, "Caches", "com.ghost.app", rule: "apps.leftover.orphan", size: 100),
         leftover(nil, "Caches", "com.other.gone", rule: "apps.leftover.orphan", size: 10)]
    }

    static func result(_ items: [ScanItem]) -> ScanResult {
        ScanResult(items: items, warnings: [], startedAt: Date(), finishedAt: Date(), wasCancelled: false)
    }
}
