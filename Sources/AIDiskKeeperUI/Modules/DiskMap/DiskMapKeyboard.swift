import DiskKeeperCore

enum MapKey: Equatable, CaseIterable { case left, right, up, down, `return`, escape }

/// What a key press does. The model applies it.
enum MapKeyAction: Equatable {
    case none
    case select(DiskNodeID)
    case zoomIn(DiskNodeID)
    case zoomOut
}

/// Pure keyboard navigation over the drawn tree. Siblings are in size order, which is also the draw order, so the
/// same semantics hold in Strata and Tiles. Aggregates are not selectable.
enum DiskMapKeyboard {
    static func action(layout: DiskMapLayout, tree: DiskTree, selected: DiskNodeID?, key: MapKey) -> MapKeyAction {
        let current = selected ?? layout.focus
        switch key {
        case .escape:
            return .zoomOut
        case .left, .right:
            guard current != layout.focus, let parent = tree.node(current).parent else { return .none }
            let siblings = drawnChildren(of: parent, layout: layout, tree: tree)
            guard let i = siblings.firstIndex(of: current) else { return .none }
            let j = key == .left ? i - 1 : i + 1
            return siblings.indices.contains(j) ? .select(siblings[j]) : .none
        case .down:
            if let first = drawnChildren(of: current, layout: layout, tree: tree).first { return .select(first) }
            return .none
        case .up:
            guard current != layout.focus, let parent = tree.node(current).parent,
                  layout.element(for: parent) != nil else { return .none }
            return .select(parent)
        case .return:
            guard current != layout.focus, canZoom(into: current, tree: tree) else { return .none }
            return .zoomIn(current)
        }
    }

    /// Children of `id` that are drawn in this layout, in size order.
    static func drawnChildren(of id: DiskNodeID, layout: DiskMapLayout, tree: DiskTree) -> [DiskNodeID] {
        tree.children(of: id).filter { layout.element(for: $0) != nil }
    }

    /// Directories and packages that have drawable children. Files, small-items nodes and other volumes can't be entered.
    static func canZoom(into id: DiskNodeID, tree: DiskTree) -> Bool {
        let node = tree.node(id)
        guard node.flags.contains(.directory) || node.flags.contains(.package),
              !node.flags.contains(.smallItems), !node.flags.contains(.otherVolume),
              node.childCount > 0, let first = tree.children(of: id).first else { return false }
        return tree.node(first).allocatedBytes > 0
    }
}
