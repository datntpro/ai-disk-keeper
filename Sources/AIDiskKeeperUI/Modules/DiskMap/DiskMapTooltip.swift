import DiskKeeperCore
import SwiftUI

/// Pure text for the hover tooltip.
struct TooltipContent: Equatable {
    var name: String
    var size: String
    var share: String
    var scannerItem: String?
    var isProtected: Bool
    var needsFullDiskAccess: Bool

    static func make(element: MapElement, tree: DiskTree, focus: DiskNodeID, overlay: DiskMapOverlay?,
                     rootName: String) -> TooltipContent {
        let focusBytes = tree.node(focus).allocatedBytes
        let fraction = focusBytes > 0 ? Double(element.bytes) / Double(focusBytes) : 0
        var item: String?
        var fda = false
        if case .node(let id) = element.kind {
            let attribution = overlay?.attribution(id)
            if attribution?.itemIDs.isEmpty == false {
                let tier = [RiskTier.keep, .review, .safe].first { attribution?.tiers.contains($0) == true }
                item = DiskMapCopy.scannerItem(tier.map(DiskMapCopy.tierName) ?? "")
            }
            fda = tree.node(id).flags.contains(.needsFullDiskAccess)
        }
        return TooltipContent(
            name: DiskMapLabels.title(of: element, tree: tree, rootName: rootName), size: Formatting.bytes(element.bytes),
            share: DiskMapCopy.share(DiskMapCopy.percent(fraction),
                                     of: DiskMapLabels.title(of: focus, tree: tree, rootName: rootName)),
            scannerItem: item, isProtected: element.isProtected, needsFullDiskAccess: fda)
    }
}

struct DiskMapTooltip: View {
    let content: TooltipContent

    var body: some View {
        SectionCard(padding: ADKTheme.Spacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(content.name).font(.caption.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                Text(content.size).font(.caption).monospacedDigit()
                Text(content.share).font(.caption).foregroundStyle(.adkText2)
                if let item = content.scannerItem { Text(item).font(.caption).foregroundStyle(.adkText2) }
                if content.isProtected { Text(DiskMapCopy.protectedTooltip).font(.caption).foregroundStyle(.adkKeepInk) }
                if content.needsFullDiskAccess { Text(DiskMapCopy.needsFDA).font(.caption).foregroundStyle(.adkText2) }
            }
        }
        .frame(maxWidth: 260, alignment: .leading)
        .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
