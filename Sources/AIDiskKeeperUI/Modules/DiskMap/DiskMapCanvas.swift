import DiskKeeperCore
import SwiftUI

extension ADKAppearance {
    init(scheme: ColorScheme, increasedContrast: Bool) {
        switch (scheme, increasedContrast) {
        case (.dark, true): self = .highContrastDark
        case (.dark, false): self = .dark
        case (_, true): self = .highContrastLight
        default: self = .light
        }
    }
}

extension RGBA {
    var swiftUIColor: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }
}

/// The map itself: one Canvas pass over every element, no per-element views. It redraws only when the layout,
/// colouring, filter or a zoom morph changes; hover and selection live in `DiskMapHighlight`.
struct DiskMapCanvas: View {
    let layout: DiskMapLayout
    let tree: DiskTree
    let paints: [ElementPaint]
    let matching: Set<Int>?
    let mode: DiskMapModel.Mode
    let rootName: String
    let transition: ZoomTransition?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.adkIncreasedContrast) private var increasedContrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let transition {
            TimelineView(.animation(paused: Date().timeIntervalSince(transition.startedAt) > ZoomTransition.duration + 0.05)) { tl in
                canvas(elapsed: tl.date.timeIntervalSince(transition.startedAt), transition: transition)
            }
        } else {
            canvas(elapsed: nil, transition: nil)
        }
    }

    private func canvas(elapsed: TimeInterval?, transition: ZoomTransition?) -> some View {
        let appearance = ADKAppearance(scheme: scheme, increasedContrast: increasedContrast)
        return Canvas(opaque: false, rendersAsynchronously: false) { ctx, _ in
            Self.draw(ctx, layout: layout, tree: tree, paints: paints, matching: matching, mode: mode, rootName: rootName,
                      appearance: appearance, morph: Self.morph(elapsed: elapsed, transition: transition, reduceMotion: reduceMotion))
        } symbols: {
            Image(systemName: "lock.fill").font(.system(size: 11, weight: .semibold)).tag(0)
        }
        .accessibilityHidden(true)
    }

    struct Morph {
        var from: [DiskNodeID: LayoutRect] = [:]
        var progress = 1.0
        var globalOpacity = 1.0
    }

    static func morph(elapsed: TimeInterval?, transition: ZoomTransition?, reduceMotion: Bool) -> Morph {
        guard let elapsed, let transition else { return Morph() }
        if reduceMotion { return Morph(globalOpacity: DiskMapTransitionMath.crossFade(elapsed: elapsed)) }
        return Morph(from: transition.from, progress: DiskMapTransitionMath.progress(elapsed: elapsed))
    }

    /// One pass in element order (parents before children).
    static func draw(_ ctx: GraphicsContext, layout: DiskMapLayout, tree: DiskTree, paints: [ElementPaint],
                     matching: Set<Int>?, mode: DiskMapModel.Mode, rootName: String, appearance: ADKAppearance,
                     morph: Morph = Morph()) {
        let separator = (appearance.isHighContrast ? ADKColor.lineStrong : ADKColor.surface).rgba(appearance).swiftUIColor
        let keep = ADKColor.keep.rgba(appearance)
        var hatchColor = keep
        hatchColor.a = appearance.isHighContrast ? 0.6 : 0.35
        let hatch = hatchColor.swiftUIColor
        var fills: [ElementPaint: (Color, ADKColor?)] = [:]
        let morphing = !morph.from.isEmpty

        for el in layout.elements where el.id < paints.count {
            let paint = paints[el.id]
            let (color, ink) = fills[paint] ?? {
                let v = (DiskMapColoring.resolvedFill(paint, appearance).swiftUIColor, DiskMapColoring.ink(for: paint, appearance))
                fills[paint] = v
                return v
            }()
            var rect = el.rect
            var alpha = morph.globalOpacity
            var nodeID: DiskNodeID?
            if case .node(let id) = el.kind { nodeID = id }
            if morphing {
                let f = DiskMapTransitionMath.frame(of: rect, node: nodeID, from: morph.from, progress: morph.progress)
                rect = f.rect
                alpha *= f.opacity
            }
            if let matching, !matching.contains(el.id) { alpha *= 0.25 }
            guard rect.width > 0, rect.height > 0 else { continue }
            let r = rect.cgRect
            let body = Path(r)
            ctx.fill(body, with: .color(color.opacity(alpha)))
            if paint.hatched { HatchPattern.draw(in: ctx, rect: r, color: hatch.opacity(alpha)) }
            ctx.stroke(Path(r.insetBy(dx: 0.5, dy: 0.5)), with: .color(separator.opacity(alpha)), lineWidth: 1)

            if DiskMapLabels.showsLock(el, flags: nodeID.map { tree.node($0).flags }), let lock = ctx.resolveSymbol(id: 0) {
                ctx.draw(lock, at: CGPoint(x: r.maxX - 11, y: r.maxY - 11))
            }
            if let ink, let label = DiskMapLabels.label(for: el, mode: mode,
                                                         title: DiskMapLabels.title(of: el, tree: tree, rootName: rootName)) {
                var c = ctx
                c.clip(to: body)
                let inkColor = ink.rgba(appearance).swiftUIColor.opacity(alpha)
                let name = c.resolve(Text(label.name).font(.caption.weight(.semibold)).foregroundColor(inkColor))
                c.draw(name, at: CGPoint(x: r.minX + 6, y: r.minY + 3), anchor: .topLeading)
                if let size = label.size {
                    let t = c.resolve(Text(size).font(.caption2).monospacedDigit().foregroundColor(inkColor))
                    c.draw(t, at: CGPoint(x: r.minX + 6, y: r.minY + 18), anchor: .topLeading)
                }
            }
        }
    }
}

/// Hover and selection rings. Only this canvas depends on `hoveredElement` and `selectedNode`, so a hover sweep
/// redraws a handful of strokes instead of the whole map.
struct DiskMapHighlight: View {
    let model: DiskMapModel
    @Environment(\.colorScheme) private var scheme
    @Environment(\.adkIncreasedContrast) private var increasedContrast

    var body: some View {
        let layout = model.layout
        let hovered = model.hoveredElement
        let selected = model.selectedNode
        let appearance = ADKAppearance(scheme: scheme, increasedContrast: increasedContrast)
        Canvas(opaque: false, rendersAsynchronously: false) { ctx, _ in
            Self.draw(ctx, layout: layout, hovered: hovered, selected: selected, appearance: appearance)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    static func draw(_ ctx: GraphicsContext, layout: DiskMapLayout?, hovered: Int?, selected: DiskNodeID?,
                     appearance: ADKAppearance) {
        guard let layout else { return }
        if let hovered, layout.elements.indices.contains(hovered) {
            let r = layout.elements[hovered].rect.cgRect.insetBy(dx: 1, dy: 1)
            ctx.stroke(Path(r), with: .color(ADKColor.accent.rgba(appearance).swiftUIColor), lineWidth: 2)
        }
        if let selected, let el = layout.element(for: selected) {
            let r = el.rect.cgRect
            ctx.stroke(Path(r.insetBy(dx: 1, dy: 1)), with: .color(ADKColor.focus.rgba(appearance).swiftUIColor), lineWidth: 2)
            ctx.stroke(Path(r.insetBy(dx: 2.5, dy: 2.5)), with: .color(.white), lineWidth: 1)
        }
    }
}
