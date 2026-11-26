import Foundation

public enum MapElementKind: Sendable, Hashable {
    case node(DiskNodeID)
    /// Children that were too small to draw, merged into one sliver/tile per parent.
    case aggregate(parent: DiskNodeID, count: Int, bytes: Int64)
}

public struct MapElement: Sendable, Hashable, Identifiable {
    /// Index in ``DiskMapLayout/elements`` (stable for one layout).
    public var id: Int
    public let kind: MapElementKind
    public let rect: LayoutRect
    /// 0 = focus.
    public let depth: Int
    /// `allocatedBytes` of the node / the aggregate.
    public let bytes: Int64
    /// The node's flags contain `.protected` or `.outsideCleanableRoots` (aggregates: false).
    public let isProtected: Bool
    /// The node has children that are not drawn (collapsed, depth limit, or merged into an aggregate).
    public let hasHiddenChildren: Bool
}

public struct StrataOptions: Sendable, Hashable {
    /// Visible depth rows including the focus row (1…16).
    public var rows: Int = 6
    /// Points; narrower children merge into one aggregate per parent.
    public var minimumWidth: Double = 2
    /// Vertical gap between rows (points).
    public var rowGap: Double = 1
    public init(rows: Int = 6, minimumWidth: Double = 2, rowGap: Double = 1) {
        self.rows = rows; self.minimumWidth = minimumWidth; self.rowGap = rowGap
    }
}

public struct TileOptions: Sendable, Hashable {
    /// 1 or 2.
    public var levels: Int = 2
    /// pt²; smaller tiles merge into one aggregate per parent.
    public var minimumArea: Double = 24
    /// Inset of level-2 tiles inside their level-1 tile.
    public var padding: Double = 2
    /// Level-1 label strip (0 = none); level-2 is laid out below it.
    public var headerHeight: Double = 16
    public init(levels: Int = 2, minimumArea: Double = 24, padding: Double = 2, headerHeight: Double = 16) {
        self.levels = levels; self.minimumArea = minimumArea; self.padding = padding; self.headerHeight = headerHeight
    }
}

/// Pure, deterministic layout of a ``DiskTree`` focus into rectangles. No file I/O, no clocks, no UI types.
/// The map is a viewer: nothing here can create or clean items (see `docs/disk-map.md`).
public struct DiskMapLayout: Sendable {
    public enum Mode: Sendable, Hashable { case strata(StrataOptions), tiles(TileOptions) }

    public let focus: DiskNodeID
    public let viewport: LayoutRect
    public let mode: Mode
    /// Draw order: parents before children; strata: row-major, x ascending.
    public let elements: [MapElement]

    let nodeIndex: [DiskNodeID: Int]
    let hitIndex: HitIndex

    enum HitIndex: Sendable {
        case none
        /// `rowStarts` has rows+1 entries (element index ranges per row); `rowHeight`/`rowGap` as laid out.
        case strata(rowStarts: [Int], rowHeight: Double, rowGap: Double)
        /// Per level-1 element index: the exclusive end of its descendants in `elements`.
        case tiles(level1: [(index: Int, end: Int)])
    }

    init(focus: DiskNodeID, viewport: LayoutRect, mode: Mode, elements: [MapElement], hitIndex: HitIndex) {
        var out = elements
        var map: [DiskNodeID: Int] = [:]
        map.reserveCapacity(out.count)
        for i in out.indices {
            out[i].id = i
            if case .node(let n) = out[i].kind { map[n] = i }
        }
        self.focus = focus; self.viewport = viewport; self.mode = mode
        self.elements = out; self.nodeIndex = map; self.hitIndex = hitIndex
    }

    public static func strata(tree: DiskTree, focus: DiskNodeID, viewport: LayoutRect,
                              options: StrataOptions = .init()) -> DiskMapLayout {
        StrataLayout.make(tree: tree, focus: focus, viewport: viewport, options: options)
    }

    public static func tiles(tree: DiskTree, focus: DiskNodeID, viewport: LayoutRect,
                             options: TileOptions = .init()) -> DiskMapLayout {
        SquarifiedLayout.make(tree: tree, focus: focus, viewport: viewport, options: options)
    }

    /// O(1).
    public func element(for node: DiskNodeID) -> MapElement? {
        nodeIndex[node].map { elements[$0] }
    }

    static let protectedMask: NodeFlags = [.protected, .outsideCleanableRoots]
}

extension DiskTree {
    /// Positive-size children exist (children are sorted by size, so the first decides).
    func hasDrawableChild(_ id: DiskNodeID) -> Bool {
        guard let first = children(of: id).first else { return false }
        return allocated[Int(first.raw)] > 0
    }

    func isProtectedForMap(_ id: DiskNodeID) -> Bool {
        flagBits[Int(id.raw)] & (DiskMapLayout.protectedMask.rawValue) != 0
    }

    func isCollapsedForMap(_ id: DiskNodeID) -> Bool {
        flagBits[Int(id.raw)] & NodeFlags.collapsed.rawValue != 0
    }
}
