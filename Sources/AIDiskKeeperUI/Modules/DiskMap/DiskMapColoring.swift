import DiskKeeperCore
import Foundation

/// How one map element is painted. Pure data: the canvas turns it into colours for the current appearance.
struct ElementPaint: Hashable, Sendable {
    enum Fill: Hashable, Sendable {
        case layer(StrataLayer)
        case age(AgeBucket)
        /// A protected path: `keepSoft` on the surface, hatched.
        case protected
    }

    var fill: Fill
    /// 1 for real nodes, 0.6 for aggregates (they merge several nodes and are neutral).
    var opacity: Double
    var hatched: Bool
}

enum DiskMapColoring {
    static let aggregateOpacity = 0.6

    static func paint(for element: MapElement, overlay: DiskMapOverlay?, colorBy: DiskMapModel.ColorBy,
                      newest: Date?, now: Date) -> ElementPaint {
        switch element.kind {
        case .aggregate:
            // Aggregates are neutral and never hatched (they carry no flags).
            let fill: ElementPaint.Fill = colorBy == .category ? .layer(.other) : .age(.unknown)
            return ElementPaint(fill: fill, opacity: aggregateOpacity, hatched: false)
        case .node(let id):
            if element.isProtected { return ElementPaint(fill: .protected, opacity: 1, hatched: true) }
            switch colorBy {
            case .category:
                let layer = StrataLayer(category: overlay?.attribution(id)?.dominantCategory)
                return ElementPaint(fill: .layer(layer), opacity: 1, hatched: false)
            case .age:
                return ElementPaint(fill: .age(DiskMapOverlay.ageBucket(newest, now: now)), opacity: 1, hatched: false)
            }
        }
    }

    /// Paints for every element of a layout, in element order.
    static func paints(layout: DiskMapLayout, tree: DiskTree, overlay: DiskMapOverlay?,
                       colorBy: DiskMapModel.ColorBy, now: Date) -> [ElementPaint] {
        layout.elements.map { el in
            var newest: Date?
            if colorBy == .age, case .node(let id) = el.kind { newest = tree.node(id).newestModification }
            return paint(for: el, overlay: overlay, colorBy: colorBy, newest: newest, now: now)
        }
    }

    /// The fill as drawn on the `surface`, opacity included (what label contrast is measured against).
    static func resolvedFill(_ paint: ElementPaint, _ appearance: ADKAppearance) -> RGBA {
        let surface = ADKColor.surface.rgba(appearance)
        let base: RGBA = switch paint.fill {
        case .layer(let l): l.rgba(appearance)
        case .age(let b): AgeRamp.rgba(b, appearance)
        case .protected: ADKColor.keepSoft.rgba(appearance)
        }
        var top = base
        top.a *= paint.opacity
        return composite(top, over: surface)
    }

    /// Label ink for the paint, or nil when neither text colour reaches 4.5:1 (the label is then skipped).
    static func ink(for paint: ElementPaint, _ appearance: ADKAppearance) -> ADKColor? {
        labelInk(onFill: resolvedFill(paint, appearance), appearance: appearance)
    }
}
