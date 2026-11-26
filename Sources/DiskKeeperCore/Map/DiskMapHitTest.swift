import Foundation

extension DiskMapLayout {
    /// The deepest element containing `point` (half-open rects: a shared edge belongs to the right/lower element).
    /// Strata: nil in row gaps, empty own-bytes space and outside the viewport. Tiles: a point inside the viewport but
    /// in a header strip, padding or empty own-bytes space returns the enclosing element.
    public func element(at point: LayoutPoint) -> MapElement? {
        guard point.x.isFinite, point.y.isFinite else { return nil }
        switch hitIndex {
        case .none:
            return nil
        case .strata(let rowStarts, let rowHeight, let rowGap):
            let rows = rowStarts.count - 1
            let dy = point.y - viewport.y
            guard dy >= 0 else { return nil }
            let rowF = dy / (rowHeight + rowGap)
            guard rowF.isFinite, rowF < Double(rows) else { return nil }   // Int(huge) would trap
            let row = Int(rowF)
            guard row >= 0, row < rows else { return nil }
            var lo = rowStarts[row], hi = rowStarts[row + 1]     // last element with x <= p.x
            guard lo < hi else { return nil }
            var found = -1
            while lo < hi {
                let mid = (lo + hi) / 2
                if elements[mid].rect.x <= point.x { found = mid; lo = mid + 1 } else { hi = mid }
            }
            guard found >= 0, elements[found].rect.contains(point) else { return nil }
            return elements[found]
        case .tiles(let level1):
            guard let focusEl = elements.first, focusEl.rect.contains(point) else { return nil }
            for g in level1 where elements[g.index].rect.contains(point) {
                var i = g.index + 1
                while i < g.end {
                    if elements[i].rect.contains(point) { return elements[i] }
                    i += 1
                }
                return elements[g.index]
            }
            return focusEl
        }
    }
}
