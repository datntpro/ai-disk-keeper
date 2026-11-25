import DiskKeeperCore
import Foundation

extension ScanItem {
    /// Non-optional sort keys for `Table` column comparators.
    var lastUsedSortKey: Date { lastModified ?? .distantPast }
    var nameWithProject: String {
        if let p = project { return "\(displayName) · \(p.displayName)" }
        return displayName
    }
    var a11yLabel: String {
        "\(displayName), \(Formatting.bytes(sizeAllocated)), tier \(TierStyle.style(for: tier).label), last used \(Formatting.relative(lastModified))"
    }
}

extension ToolID {
    var uiName: String { knownDisplayName ?? rawValue }
}
