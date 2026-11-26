import Foundation

/// Squarified treemap (Bruls, Huizing, van Wijk 2000) over the focus's children, optionally one nested level.
enum SquarifiedLayout {
    /// Lays out `values` (descending, all > 0, Σ ≈ area(rect)) inside `rect`. Returns one rect per value, in order.
    /// Strips run along the shorter side; offsets are cumulative so neighbours share edges to within 1 ULP.
    static func squarify(values: [Double], in rect: LayoutRect) -> [LayoutRect] {
        var out: [LayoutRect] = []
        out.reserveCapacity(values.count)
        var r = rect
        var i = 0
        let n = values.count
        while i < n {
            let horizontalStrip = r.width < r.height   // strip across the top when the rect is tall
            let side = horizontalStrip ? r.width : r.height
            var j = i + 1
            var sum = values[i], mx = values[i], mn = values[i]
            var worst = worstRatio(sum: sum, mx: mx, mn: mn, side: side)
            while j < n {
                let v = values[j]
                let s2 = sum + v, mx2 = max(mx, v), mn2 = min(mn, v)
                let w2 = worstRatio(sum: s2, mx: mx2, mn: mn2, side: side)
                if w2 <= worst { sum = s2; mx = mx2; mn = mn2; worst = w2; j += 1 } else { break }
            }
            let last = j >= n
            let full = horizontalStrip ? r.height : r.width
            let thickness = last ? full : min(full, side > 0 ? sum / side : 0)
            var cum = 0.0
            for k in i..<j {
                let a = cum
                cum += values[k]
                let t0 = side * a / sum
                let t1 = k == j - 1 ? side : side * cum / sum
                if horizontalStrip {
                    out.append(LayoutRect(x: r.x + t0, y: r.y, width: t1 - t0, height: thickness))
                } else {
                    out.append(LayoutRect(x: r.x, y: r.y + t0, width: thickness, height: t1 - t0))
                }
            }
            if horizontalStrip {
                r = LayoutRect(x: r.x, y: r.y + thickness, width: r.width, height: max(0, r.height - thickness))
            } else {
                r = LayoutRect(x: r.x + thickness, y: r.y, width: max(0, r.width - thickness), height: r.height)
            }
            i = j
        }
        return out
    }

    private static func worstRatio(sum: Double, mx: Double, mn: Double, side: Double) -> Double {
        guard side > 0, sum > 0, mn > 0 else { return .infinity }
        let w2 = side * side, s2 = sum * sum
        return max(w2 * mx / s2, s2 / (w2 * mn))
    }

    private struct Item {
        var node: DiskNodeID?          // nil: aggregate (count/bytes) or gap
        var bytes: Int64
        var count: Int = 0
        var isGap = false
    }

    /// Children items for `parent` scaled into `rect`; small ones merged into a trailing aggregate; an optional
    /// invisible own-bytes gap item last.
    private static func items(tree: DiskTree, parent: DiskNodeID, rect: LayoutRect, minArea: Double,
                              withGap: Bool) -> (items: [Item], values: [Double]) {
        var kids: [Item] = []
        var sum: Int64 = 0
        for c in tree.children(of: parent) {
            let b = tree.allocated[Int(c.raw)]
            if b <= 0 { break }
            kids.append(Item(node: c, bytes: b))
            sum += b
        }
        let own = tree.allocated[Int(parent.raw)]
        let gap = withGap ? max(0, own - sum) : 0
        let total = sum + gap
        guard total > 0, !kids.isEmpty else { return ([], []) }
        let scale = rect.area / Double(total)
        var cut = kids.count
        while cut > 0, Double(kids[cut - 1].bytes) * scale < minArea { cut -= 1 }
        var out = Array(kids[0..<cut])
        if cut < kids.count {
            let tail = kids[cut...]
            out.append(Item(node: nil, bytes: tail.reduce(0) { $0 + $1.bytes }, count: tail.count))
        }
        if gap > 0 { out.append(Item(node: nil, bytes: gap, isGap: true)) }
        return (out, out.map { Double($0.bytes) * scale })
    }

    static func make(tree: DiskTree, focus: DiskNodeID, viewport: LayoutRect, options: TileOptions) -> DiskMapLayout {
        let mode = DiskMapLayout.Mode.tiles(options)
        guard viewport.isFinite, viewport.width > 0, viewport.height > 0, Int(focus.raw) < tree.nodeCount else {
            return DiskMapLayout(focus: focus, viewport: viewport, mode: mode, elements: [], hitIndex: .none)
        }
        let minArea = options.minimumArea.isFinite ? max(0, options.minimumArea) : 0
        let padding = options.padding.isFinite ? max(0, options.padding) : 0
        let header = options.headerHeight.isFinite ? max(0, options.headerHeight) : 0
        let twoLevels = options.levels >= 2

        var elements: [MapElement] = []
        var level1: [(index: Int, end: Int)] = []

        let l1 = items(tree: tree, parent: focus, rect: viewport, minArea: minArea, withGap: false)
        let l1Rects = squarify(values: l1.values, in: viewport)
        let focusHidden = tree.isCollapsedForMap(focus) || l1.items.contains { $0.node == nil }
            || (!tree.hasDrawableChild(focus) ? false : l1.items.isEmpty)
        elements.append(MapElement(id: 0, kind: .node(focus), rect: viewport, depth: 0, bytes: tree.allocated[Int(focus.raw)],
                                   isProtected: tree.isProtectedForMap(focus), hasHiddenChildren: focusHidden))

        for (item, rect) in zip(l1.items, l1Rects) {
            let start = elements.count
            guard let node = item.node else {
                elements.append(MapElement(id: 0, kind: .aggregate(parent: focus, count: item.count, bytes: item.bytes),
                                           rect: rect, depth: 1, bytes: item.bytes, isProtected: false, hasHiddenChildren: false))
                level1.append((start, elements.count))
                continue
            }
            let canNest = twoLevels && rect.area >= 4 * minArea && tree.hasDrawableChild(node)
            var inner: [MapElement] = []
            var hidden = tree.isCollapsedForMap(node) || (!twoLevels && tree.hasDrawableChild(node))
            if canNest {
                var box = rect.inset(by: padding)
                if header > 0, box.height > 2 * header {
                    box = LayoutRect(x: box.x, y: box.y + header, width: box.width, height: box.height - header)
                }
                if box.width > 0, box.height > 0 {
                    let l2 = items(tree: tree, parent: node, rect: box, minArea: minArea, withGap: true)
                    let rects = squarify(values: l2.values, in: box)
                    for (it, r) in zip(l2.items, rects) where !it.isGap {
                        if let c = it.node {
                            inner.append(MapElement(id: 0, kind: .node(c), rect: r, depth: 2, bytes: it.bytes,
                                                    isProtected: tree.isProtectedForMap(c),
                                                    hasHiddenChildren: tree.isCollapsedForMap(c) || tree.hasDrawableChild(c)))
                        } else {
                            hidden = true
                            inner.append(MapElement(id: 0, kind: .aggregate(parent: node, count: it.count, bytes: it.bytes),
                                                    rect: r, depth: 2, bytes: it.bytes, isProtected: false, hasHiddenChildren: false))
                        }
                    }
                } else if tree.hasDrawableChild(node) { hidden = true }
            } else if tree.hasDrawableChild(node) { hidden = true }
            elements.append(MapElement(id: 0, kind: .node(node), rect: rect, depth: 1, bytes: item.bytes,
                                       isProtected: tree.isProtectedForMap(node), hasHiddenChildren: hidden))
            elements.append(contentsOf: inner)
            level1.append((start, elements.count))
        }
        return DiskMapLayout(focus: focus, viewport: viewport, mode: mode, elements: elements, hitIndex: .tiles(level1: level1))
    }
}
