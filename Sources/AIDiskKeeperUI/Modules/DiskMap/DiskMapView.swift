import AppKit
import DiskKeeperCore
import SwiftUI

struct DiskMapView: View {
    let model: DiskMapModel
    let ctx: ModuleContext

    var body: some View {
        IndexGateView(index: ctx.suite.diskIndex) { _ in
            DiskMapContent(model: model, ctx: ctx)
        }
    }
}

private struct DiskMapContent: View {
    let model: DiskMapModel
    let ctx: ModuleContext

    private var index: DiskIndexModel { ctx.suite.diskIndex }

    var body: some View {
        VStack(alignment: .leading, spacing: ADKTheme.Spacing.md) {
            header
            if index.phase == .indexing { ProgressView().progressViewStyle(.linear).accessibilityLabel(DiskMapCopy.reindexing) }
            toolbar
            legend
            DiskMapStage(model: model, ctx: ctx)
            DiskMapBreadcrumbs(crumbs: model.breadcrumbs) { model.zoom(toCrumb: $0.id) }
        }
        .padding(ADKTheme.Spacing.lg)
        .task(id: index.generation) { model.treeChanged() }
        .onChange(of: ctx.scan.items.count) { model.scanChanged() }
        .onChange(of: ctx.scan.scanGeneration) { model.scanChanged() }
        .onAppear { model.scanChanged() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: ADKTheme.Spacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(DiskMapModule.descriptor.title).font(ADKTheme.Font.largeTitle)
                if let tree = model.tree {
                    TimelineView(.periodic(from: .now, by: 30)) { _ in
                        Text(DiskMapCopy.subtitle(scope: model.rootName, size: Formatting.bytes(tree.node(tree.rootNodeID).allocatedBytes),
                                                  indexed: Formatting.relative(index.builtAt)))
                            .font(.callout).foregroundStyle(.adkText2)
                    }
                }
            }
            Spacer()
            scopeMenu
            Button(loc("index.reindex", "Re-index")) { index.start(index.scope) }
                .disabled(index.phase == .indexing)
        }
    }

    private var scopeMenu: some View {
        Menu {
            Button(DiskMapCopy.scopeHome) { index.start(.home) }
            Button(DiskMapCopy.scopeFullDisk) { index.start(.fullDisk) }
                .disabled(!index.fullDiskAvailable)
            if !index.fullDiskAvailable { Text(DiskMapCopy.scopeNeedsFDA) }
        } label: {
            Text(DiskMapCopy.scopeLabel)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(index.phase == .indexing)
        .help(index.fullDiskAvailable ? DiskMapCopy.scopeLabel : DiskMapCopy.scopeNeedsFDA)
    }

    private var toolbar: some View {
        HStack(spacing: ADKTheme.Spacing.md) {
            Picker(DiskMapCopy.viewMode, selection: Binding(get: { model.mode }, set: { model.setMode($0) })) {
                Text(DiskMapCopy.modeStrata).tag(DiskMapModel.Mode.strata)
                Text(DiskMapCopy.modeTiles).tag(DiskMapModel.Mode.tiles)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            Picker(DiskMapCopy.viewColor, selection: Binding(get: { model.colorBy }, set: { model.setColorBy($0) })) {
                Text(DiskMapCopy.colorCategory).tag(DiskMapModel.ColorBy.category)
                Text(DiskMapCopy.colorAge).tag(DiskMapModel.ColorBy.age)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            Spacer()
            TextField(DiskMapCopy.filter, text: Binding(get: { model.filterText }, set: { model.setFilterText($0) }))
                .textFieldStyle(.roundedBorder).frame(maxWidth: 220)
        }
    }

    private var legend: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: ADKTheme.Spacing.md) {
                if model.colorBy == .category {
                    ForEach(model.presentLayers, id: \.self) { LegendChip(color: $0.color, label: $0.title) }
                } else {
                    ForEach([AgeBucket.lastMonth, .last6Months, .lastYear, .last3Years, .older, .unknown], id: \.self) {
                        LegendChip(color: AgeRamp.color($0), label: AgeRamp.title($0))
                    }
                }
                if model.hasProtectedElements {
                    HStack(spacing: 6) {
                        HatchPattern().stroke(Color.adkKeep, lineWidth: 1)
                            .frame(width: 12, height: 12).background(.adkKeepSoft).clipShape(RoundedRectangle(cornerRadius: 2))
                            .accessibilityHidden(true)
                        Text(DiskMapCopy.legendProtected).font(.caption).foregroundStyle(.adkText2)
                    }
                }
                if !model.hasScanItems, model.colorBy == .category {
                    Label(DiskMapCopy.scanHint, systemImage: "info.circle").font(.caption).foregroundStyle(.adkText2)
                }
                if let note = model.incompleteNote {
                    Label(note, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.adkText2)
                }
            }
        }
    }
}

/// The map area: canvas, rings, tooltip and the interaction layer.
private struct DiskMapStage: View {
    let model: DiskMapModel
    let ctx: ModuleContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var rotorSpace
    @Environment(\.adkIncreasedContrast) private var increasedContrast

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                if let layout = model.layout, let tree = model.tree {
                    DiskMapCanvas(layout: layout, tree: tree, paints: model.paints, matching: model.matchingElements,
                                  mode: model.mode, rootName: model.rootName, transition: model.transition)
                    DiskMapHighlight(model: model)
                }
                DiskMapTooltipLayer(model: model, size: geo.size)
                DiskMapInteractionLayer(model: model)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .onChange(of: geo.size, initial: true) { _, size in model.viewportChanged(size) }
        }
        .frame(minHeight: 300)
        .background(.adkSunken)
        .clipShape(RoundedRectangle(cornerRadius: ADKTheme.Radius.lg))
        .overlay {
            RoundedRectangle(cornerRadius: ADKTheme.Radius.lg)
                .strokeBorder(increasedContrast ? .adkLineStrong : .adkLine, lineWidth: ADKTheme.hairline)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(DiskMapCopy.container(model.rootName))
        .accessibilityChildren {
            ZStack(alignment: .topLeading) {
                ForEach(model.axRows) { row in
                    Rectangle().fill(Color.clear)
                        .frame(width: row.rect.width, height: row.rect.height)
                        .position(x: row.rect.midX, y: row.rect.midY)
                        .accessibilityLabel(row.label)
                        .accessibilityAddTraits(.isButton)
                        .accessibilityRotorEntry(id: row.id, in: rotorSpace)
                        .accessibilityAction { model.zoom(into: row.id) }
                        .accessibilityAction(named: Text(DiskMapCopy.reveal)) { FinderReveal.reveal(URL(fileURLWithPath: row.revealPath)) }
                        .accessibilityAction(named: Text(DiskMapCopy.reviewInList)) {
                            if let id = row.reviewItemID { DiskMapModule.review(id, ctx) }
                        }
                }
            }
        }
        .accessibilityRotor(Text(DiskMapCopy.a11yRotor)) {
            ForEach(model.axRows.sorted { $0.bytes > $1.bytes }) { row in
                AccessibilityRotorEntry(Text(row.label), id: row.id, in: rotorSpace)
            }
        }
    }
}

private struct DiskMapTooltipLayer: View {
    let model: DiskMapModel
    let size: CGSize

    var body: some View {
        if let id = model.tooltipElement, let layout = model.layout, let tree = model.tree, let f = model.focusID,
           layout.elements.indices.contains(id) {
            let content = TooltipContent.make(element: layout.elements[id], tree: tree, focus: f, overlay: model.overlay,
                                              rootName: model.rootName)
            let anchor = model.tooltipAnchor
            DiskMapTooltip(content: content)
                .fixedSize()
                .offset(x: min(max(0, anchor.x + 14), max(0, size.width - 250)),
                        y: min(max(0, anchor.y + 14), max(0, size.height - 110)))
        }
    }
}

/// Pointer, tap, context menu and keyboard. It reads no hover state while rendering, so hovering never re-renders
/// the map; the context menu reads it only when it opens.
private struct DiskMapInteractionLayer: View {
    let model: DiskMapModel

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let p): model.hover(p)
                case .ended: model.hover(nil)
                }
            }
            .gesture(SpatialTapGesture().onEnded { model.click($0.location) })
            .contextMenu {
                if let t = model.contextTarget {
                    Button(DiskMapCopy.zoomIn) { model.zoom(into: t.node) }.disabled(!t.canZoom)
                    Button(DiskMapCopy.reveal) { FinderReveal.reveal(URL(fileURLWithPath: t.revealPath)) }
                    Button(DiskMapCopy.copyPath) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(t.revealPath, forType: .string)
                    }
                }
            }
            .focusable()
            .focusEffectDisabled()
            .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow, .return, .escape]) { press in
                let key: MapKey? = switch press.key {
                case .leftArrow: .left
                case .rightArrow: .right
                case .upArrow: press.modifiers.contains(.command) ? .escape : .up
                case .downArrow: .down
                case .return: .return
                case .escape: .escape
                default: nil
                }
                guard let key else { return .ignored }
                return model.handleKey(key) ? .handled : .ignored
            }
            .accessibilityHidden(true)
    }
}
