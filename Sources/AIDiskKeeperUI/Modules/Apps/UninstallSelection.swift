import DiskKeeperCore
import Foundation

/// How a leftover is tied to its app. Drives the pill and whether the row starts ticked.
enum UninstallRelatedKind: Equatable {
    case exact, launchAgent, name, shared

    init(_ item: ScanItem) {
        switch item.ruleID {
        case "apps.leftover.exact": self = UninstallLibrary.location(of: item.path) == "LaunchAgents" ? .launchAgent : .exact
        case "apps.leftover.name": self = item.groupID == nil ? .shared : .name
        default: self = .shared
        }
    }

    var startsTicked: Bool { self == .exact || self == .launchAgent }
}

/// Pure helpers over `~/Library` paths.
enum UninstallLibrary {
    /// Locations whose contents an app rebuilds by itself: what "Reset app only" moves. Preferences are guard
    /// protected (never offered); Application Support and Containers hold user data.
    static let resetLocations: Set<String> = ["Caches", "HTTPStorages", "WebKit", "Saved Application State", "Logs"]

    /// The folder directly under `~/Library` that holds `path` (e.g. "Caches"), or nil.
    static func location(of path: String) -> String? {
        let parts = path.split(separator: "/").map(String.init)
        guard let i = parts.firstIndex(of: "Library"), i + 2 < parts.count else { return nil }
        return parts[i + 1]
    }

    static func isRegenerable(_ item: ScanItem) -> Bool {
        item.ruleID == "apps.leftover.exact" && item.isSelectable
            && location(of: item.path).map(resetLocations.contains) == true
    }

    /// Case- and diacritic-insensitive comparison key for names.
    static func fold(_ s: String) -> String {
        s.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// `/Users/me/Library/Caches/x` → `~/Library/Caches/x`.
    static func tilde(_ path: String, home: String) -> String {
        path == home ? "~" : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    /// The bundle id an orphan entry is named after (`com.x.y.plist`, `com.x.y.savedState`, …).
    static func orphanKey(_ item: ScanItem) -> String {
        var name = (item.path as NSString).lastPathComponent
        for suffix in [".plist", ".savedState", ".binarycookies"] where name.hasSuffix(suffix) { name = String(name.dropLast(suffix.count)) }
        return name
    }
}

/// The leftovers that belong to one app, in screen order.
struct UninstallGroup: Equatable {
    var related: [ScanItem] = []
    var shared: [ScanItem] = []
    var all: [ScanItem] { related + shared }
    var resetItems: [ScanItem] { related.filter(UninstallLibrary.isRegenerable) }
}

/// What is ticked for the app on screen. The bundle itself is implicit (it is what "Uninstall" means), so only
/// leftovers live here. Exact matches start ticked; name-level and shared ones never do.
struct UninstallSelection: Equatable {
    private(set) var appID: InstalledApp.ID?
    private(set) var ticked: Set<ScanItem.ID> = []

    init() {}

    init(app: InstalledApp, group: UninstallGroup) {
        appID = app.id
        ticked = Set(group.related.filter { UninstallRelatedKind($0).startsTicked && $0.isSelectable }.map(\.id))
    }

    /// Only items of the group on screen, and only ones the engine could ever act on.
    static func canToggle(_ item: ScanItem, in group: UninstallGroup) -> Bool {
        item.isSelectable && group.all.contains { $0.id == item.id }
    }

    func isTicked(_ item: ScanItem) -> Bool { ticked.contains(item.id) }

    /// Refused (no change) when `canToggle` is false. Ticking a shared entry unticks any other shared one:
    /// they go one at a time, by hand.
    mutating func toggle(_ item: ScanItem, in group: UninstallGroup) {
        guard Self.canToggle(item, in: group) else { return }
        if ticked.remove(item.id) != nil { return }
        if group.shared.contains(where: { $0.id == item.id }) { ticked.subtract(group.shared.map(\.id)) }
        ticked.insert(item.id)
    }

    /// The ticked leftovers in screen order.
    func items(in group: UninstallGroup) -> [ScanItem] {
        group.all.filter { ticked.contains($0.id) && $0.isSelectable }
    }

    mutating func remove(_ ids: Set<ScanItem.ID>) { ticked.subtract(ids) }
}
