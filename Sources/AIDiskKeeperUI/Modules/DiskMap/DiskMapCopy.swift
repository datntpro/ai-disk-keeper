import DiskKeeperCore
import Foundation

/// Every user-visible string of the Disk Map. Keys are prefixed `map.`; numbers arrive pre-formatted.
enum DiskMapCopy {
    static var scopeHome: String { loc("map.scope.home", "Home folder") }
    static var scopeFullDisk: String { loc("map.scope.fullDisk", "Whole disk") }
    static var scopeNeedsFDA: String { loc("map.scope.needsFDA", "Needs Full Disk Access") }
    static var modeStrata: String { loc("map.mode.strata", "Strata") }
    static var modeTiles: String { loc("map.mode.tiles", "Tiles") }
    static var colorCategory: String { loc("map.color.category", "By category") }
    static var colorAge: String { loc("map.color.age", "By age") }
    static var filter: String { loc("map.filter", "Filter folders") }
    static var legendProtected: String { loc("map.legend.protected", "hatched = protected, never offered") }
    static var scanHint: String { loc("map.hint.scanForColours", "Scan to colour folders by what they are") }
    static var viewMode: String { loc("map.mode.label", "Layout") }
    static var viewColor: String { loc("map.color.label", "Colour") }
    static var scopeLabel: String { loc("map.scope.label", "Scope") }
    static var largestInside: String { loc("map.inspector.largest", "Largest inside") }
    static var notClassifiedTitle: String { loc("map.inspector.notClassified.title", "Not classified") }
    static var notClassifiedBody: String {
        loc("map.inspector.notClassified.body", "No rule explains this folder, so it is shown for orientation only. You can open it in Finder.")
    }
    static var protectedNote: String {
        loc("map.inspector.protected", "Protected — AI Disk Keeper never offers this for cleanup.")
    }
    static var insideMatch: String { loc("map.inspector.insideMatch", "Matches an item inside this folder") }
    static var reviewInList: String { loc("map.action.reviewInList", "Review in list") }
    static var reveal: String { loc("action.reveal", "Reveal in Finder") }
    static var zoomIn: String { loc("map.action.zoomIn", "Zoom in") }
    static var zoomOut: String { loc("map.action.zoomOut", "Zoom out") }
    static var copyPath: String { loc("map.action.copyPath", "Copy path") }
    static var protectedTooltip: String { loc("map.tooltip.protected", "Protected path") }
    static var needsFDA: String { loc("map.needsFDA", "Needs Full Disk Access") }
    static var a11yRotor: String { loc("map.a11y.rotor", "Largest folders") }
    static var a11yProtected: String { loc("map.a11y.protected", "protected") }
    static var incompleteBudget: String { loc("map.incomplete.budget", "Large tree — deep folders are summarised") }
    static var breadcrumbs: String { loc("map.breadcrumbs", "Location in the disk map") }
    static var inspectorTitle: String { loc("map.inspector.title", "Details") }
    static var noSelection: String { loc("map.inspector.none", "Select a folder on the map to see details.") }
    static func logicalSize(_ size: String) -> String { loc("map.inspector.logical", "Apparent size: \(size)") }
    static var files: String { loc("map.inspector.files", "Files") }
    static var modified: String { loc("map.inspector.modified", "Newest change") }
    static var kindLabel: String { loc("map.inspector.kind", "Kind") }
    static var reindexing: String { loc("map.reindexing", "Re-indexing…") }

    static func subtitle(scope: String, size: String, indexed: String) -> String {
        loc("map.subtitle", "\(scope) · \(size) · indexed \(indexed)")
    }
    static func smallItems(_ count: String) -> String { loc("map.smallItems", "\(count) small items") }
    static func aggregate(count: String, size: String) -> String { loc("map.aggregate", "\(count) more · \(size)") }
    static func share(_ percent: String, of name: String) -> String { loc("map.tooltip.share", "\(percent) of \(name)") }
    static func scannerItem(_ tier: String) -> String { loc("map.tooltip.item", "Scanner item · \(tier)") }
    static func ofParent(_ percent: String) -> String { loc("map.inspector.ofParent", "\(percent) of parent folder") }
    static func incompleteUnreadable(_ count: String) -> String {
        loc("map.incomplete.unreadable", "Some folders couldn't be read (\(count))")
    }
    static func nodeA11y(name: String, size: String, percent: String, of focus: String) -> String {
        loc("map.node.a11y", "\(name), \(size), \(percent) percent of \(focus)")
    }
    static func container(_ name: String) -> String { loc("map.a11y.container", "Disk map of \(name)") }
    static func scannerItemA11y(_ tier: String) -> String { loc("map.a11y.scannerItem", "scanner item: \(tier)") }

    enum Kind: CaseIterable { case folder, package, file, smallItems, otherVolume, iCloud }
    static func kind(_ k: Kind) -> String {
        switch k {
        case .folder: loc("map.kind.folder", "Folder")
        case .package: loc("map.kind.package", "Package")
        case .file: loc("map.kind.file", "File")
        case .smallItems: loc("map.kind.smallItems", "Small items")
        case .otherVolume: loc("map.kind.otherVolume", "Other volume")
        case .iCloud: loc("map.kind.iCloud", "iCloud only")
        }
    }

    enum Note: CaseIterable { case dataless, hardlink, sparse, compressed, unreadable }
    static func note(_ n: Note) -> String {
        switch n {
        case .dataless: loc("map.note.dataless", "Stored in iCloud; not downloaded to this Mac")
        case .hardlink: loc("map.note.hardlink", "Another link to a file already counted; adds no size")
        case .sparse: loc("map.note.sparse", "Sparse file: uses less space than its apparent size")
        case .compressed: loc("map.note.compressed", "Compressed by macOS")
        case .unreadable: loc("map.note.unreadable", "Couldn't be read")
        }
    }

    static func tierName(_ t: RiskTier) -> String { TierStyle.style(for: t).label }

    /// Locale-aware percentage with one decimal ("12.5%").
    static func percent(_ fraction: Double) -> String {
        fraction.formatted(.percent.precision(.fractionLength(1)).locale(L10n.locale))
    }

    /// The number alone ("12.5"), for VoiceOver text that already says "percent".
    static func percentNumber(_ fraction: Double) -> String {
        (fraction * 100).formatted(.number.precision(.fractionLength(1)).locale(L10n.locale))
    }
}
