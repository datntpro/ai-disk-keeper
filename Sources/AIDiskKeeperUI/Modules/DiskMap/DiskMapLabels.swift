import DiskKeeperCore
import Foundation

/// Which elements get a text label, and what it says. Pure.
enum DiskMapLabels {
    struct Label: Equatable {
        var name: String
        /// Shown on a second line when there is room.
        var size: String?
    }

    /// Display name of a node: the root shows the scope, small-items nodes are localized.
    static func title(of id: DiskNodeID, tree: DiskTree, rootName: String) -> String {
        if id == tree.rootNodeID { return rootName }
        let node = tree.node(id)
        if node.flags.contains(.smallItems) { return DiskMapCopy.smallItems(Formatting.count(node.fileCount)) }
        return node.name
    }

    static func title(of element: MapElement, tree: DiskTree, rootName: String) -> String {
        switch element.kind {
        case .node(let id): return title(of: id, tree: tree, rootName: rootName)
        case .aggregate(_, let count, let bytes):
            return DiskMapCopy.aggregate(count: Formatting.count(count), size: Formatting.bytes(bytes))
        }
    }

    /// Strata: width ≥ 56 and height ≥ 16 → name, plus size when the cell is 32 pt tall.
    /// Tiles: level-1 tiles with area ≥ 3 600 pt² and width ≥ 56 show their name in the header strip; level-2 tiles
    /// show a name when they are at least 56 × 28.
    static func label(for element: MapElement, mode: DiskMapModel.Mode, title: @autoclosure () -> String) -> Label? {
        let w = element.rect.width, h = element.rect.height
        switch mode {
        case .strata:
            guard w >= 56, h >= 16 else { return nil }
            return Label(name: title(), size: h >= 32 ? Formatting.bytes(element.bytes) : nil)
        case .tiles:
            switch element.depth {
            case 0: return nil
            case 1:
                guard element.rect.area >= 3_600, w >= 56 else { return nil }
                return Label(name: title(), size: w >= 120 ? Formatting.bytes(element.bytes) : nil)
            default:
                guard w >= 56, h >= 28 else { return nil }
                return Label(name: title(), size: h >= 40 ? Formatting.bytes(element.bytes) : nil)
            }
        }
    }

    /// The lock glyph is drawn when the rect is at least 18 × 18.
    static func showsLock(_ element: MapElement, flags: NodeFlags?) -> Bool {
        guard element.rect.width >= 18, element.rect.height >= 18 else { return false }
        if element.isProtected { return true }
        return flags?.contains(.needsFullDiskAccess) == true
    }
}
