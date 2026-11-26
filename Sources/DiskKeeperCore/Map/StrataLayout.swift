import Foundation

/// Icicle / partition layout: row 0 is the focus at full width; each next row splits the parent's span among
/// its children in proportion to `allocatedBytes`. Positions come from cumulative sums (no drift).
enum StrataLayout {
    static func make(tree: DiskTree, focus: DiskNodeID, viewport: LayoutRect, options: StrataOptions) -> DiskMapLayout {
        let mode = DiskMapLayout.Mode.strata(options)
        let rows = min(16, max(1, options.rows))
        let gap = options.rowGap.isFinite ? max(0, options.rowGap) : 0
        let minW = options.minimumWidth.isFinite ? max(0, options.minimumWidth) : 0
        let rowH = (viewport.height - Double(rows - 1) * gap) / Double(rows)
        guard viewport.isFinite, viewport.width > 0, viewport.height > 0, rowH > 0, Int(focus.raw) < tree.nodeCount else {
            return DiskMapLayout(focus: focus, viewport: viewport, mode: mode, elements: [], hitIndex: .none)
        }

        var perRow = [[MapElement]](repeating: [], count: rows)

        func emit(kind: MapElementKind, x0: Double, x1: Double, depth: Int, bytes: Int64, prot: Bool, hidden: Bool) {
            let rect = LayoutRect(x: x0, y: viewport.y + Double(depth) * (rowH + gap), width: x1 - x0, height: rowH)
            perRow[depth].append(MapElement(id: 0, kind: kind, rect: rect, depth: depth, bytes: bytes,
                                            isProtected: prot, hasHiddenChildren: hidden))
        }

        func place(_ node: DiskNodeID, _ x0: Double, _ x1: Double, _ depth: Int) {
            let i = Int(node.raw)
            let total = tree.allocated[i]
            let collapsed = tree.isCollapsedForMap(node)
            let kids = tree.children(of: node)
            let canExpand = depth < rows - 1 && total > 0 && !kids.isEmpty
            var cum: Int64 = 0
            var smallCount = 0
            var smallBytes: Int64 = 0
            var childPlacements: [(DiskNodeID, Double, Double)] = []
            if canExpand {
                let span = x1 - x0
                var idx = kids.startIndex
                while idx < kids.endIndex {
                    let c = kids[idx]
                    let b = tree.allocated[Int(c.raw)]
                    if b <= 0 { break }                       // sorted desc: the rest are zero-byte
                    let remaining = max(0, total - cum)
                    let eff = min(b, remaining)               // clamp: never draw outside the parent
                    if span * Double(eff) / Double(total) < minW {
                        // sorted desc: this and every later positive child is too narrow
                        var j = idx
                        while j < kids.endIndex {
                            let bj = tree.allocated[Int(kids[j].raw)]
                            if bj <= 0 { break }
                            smallCount += 1; smallBytes += bj
                            j += 1
                        }
                        break
                    }
                    let a = x0 + span * Double(cum) / Double(total)
                    cum += eff
                    let e = x0 + span * Double(cum) / Double(total)
                    childPlacements.append((c, a, e))
                    idx += 1
                }
            }
            let hidden = collapsed || smallCount > 0 || (!canExpand && tree.hasDrawableChild(node))
            emit(kind: .node(node), x0: x0, x1: x1, depth: depth, bytes: total,
                 prot: tree.isProtectedForMap(node), hidden: hidden)
            for (c, a, e) in childPlacements { place(c, a, e, depth + 1) }
            if smallCount > 0 {
                let span = x1 - x0
                let a = x0 + span * Double(cum) / Double(total)
                let eb = min(total, cum + smallBytes)
                let e = x0 + span * Double(eb) / Double(total)
                if e > a {
                    emit(kind: .aggregate(parent: node, count: smallCount, bytes: smallBytes), x0: a, x1: e,
                         depth: depth + 1, bytes: smallBytes, prot: false, hidden: false)
                }
            }
        }

        place(focus, viewport.x, viewport.x + viewport.width, 0)

        var all: [MapElement] = []
        var starts = [0]
        for r in perRow { all.append(contentsOf: r); starts.append(all.count) }
        return DiskMapLayout(focus: focus, viewport: viewport, mode: mode, elements: all,
                             hitIndex: .strata(rowStarts: starts, rowHeight: rowH, rowGap: gap))
    }
}
