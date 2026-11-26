import DiskKeeperCore
import SwiftUI

/// One invisible VoiceOver proxy over a drawn node. The map itself is a Canvas, so these carry the semantics.
struct AXRow: Identifiable, Equatable {
    let id: DiskNodeID
    let label: String
    let rect: CGRect
    let bytes: Int64
    let canZoom: Bool
    let reviewItemID: ScanItem.ID?
    let revealPath: String
}

enum DiskMapAccessibility {
    static let rowCap = 200

    /// The focus's direct children (largest first, at most 200) plus the selection and its ancestors below the focus.
    static func rows(layout: DiskMapLayout, tree: DiskTree, selection: DiskNodeID?, overlay: DiskMapOverlay?,
                     rootName: String) -> [AXRow] {
        var ids = Array(DiskMapKeyboard.drawnChildren(of: layout.focus, layout: layout, tree: tree).prefix(rowCap))
        if let selection, selection != layout.focus {
            var chain = [selection]
            var cur = tree.node(selection).parent
            while let p = cur, p != layout.focus { chain.append(p); cur = tree.node(p).parent }
            for id in chain.reversed() where !ids.contains(id) && layout.element(for: id) != nil { ids.append(id) }
        }
        let focusBytes = tree.node(layout.focus).allocatedBytes
        let focusName = DiskMapLabels.title(of: layout.focus, tree: tree, rootName: rootName)
        return ids.compactMap { id in
            guard let el = layout.element(for: id) else { return nil }
            let node = tree.node(id)
            let fraction = focusBytes > 0 ? Double(node.allocatedBytes) / Double(focusBytes) : 0
            var label = DiskMapCopy.nodeA11y(
                name: DiskMapLabels.title(of: id, tree: tree, rootName: rootName), size: Formatting.bytes(node.allocatedBytes),
                percent: DiskMapCopy.percentNumber(fraction), of: focusName)
            if el.isProtected { label += ", " + DiskMapCopy.a11yProtected }
            let attribution = overlay?.attribution(id)
            if attribution?.itemIDs.isEmpty == false {
                let tier = [RiskTier.keep, .review, .safe].first { attribution?.tiers.contains($0) == true }
                label += ", " + DiskMapCopy.scannerItemA11y(tier.map(DiskMapCopy.tierName) ?? "")
            }
            let flags = node.flags
            let revealID = (flags.contains(.smallItems) ? node.parent : nil) ?? id
            return AXRow(id: id, label: label, rect: el.rect.cgRect, bytes: node.allocatedBytes,
                         canZoom: DiskMapKeyboard.canZoom(into: id, tree: tree),
                         reviewItemID: attribution?.itemIDs.first, revealPath: tree.path(of: revealID))
        }
    }
}
