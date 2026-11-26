import DiskKeeperCore
import Foundation

extension ScanItem {
    /// Non-optional sort keys for `Table` column comparators.
    var lastUsedSortKey: Date { lastModified ?? .distantPast }
    var a11yLabel: String {
        var s = loc("row.a11y", "\(uiDisplayName()), \(Formatting.bytes(sizeAllocated)), tier \(TierStyle.style(for: tier).label), last used \(Formatting.relative(lastModified))")
        if let id = requiresAppQuit { s += loc("row.a11y.quit", ", requires quitting \(AppNameResolver.name(forBundleID: id))") }
        return s
    }
}
