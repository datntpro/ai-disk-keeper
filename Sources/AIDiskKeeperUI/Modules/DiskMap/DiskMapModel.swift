import AppKit
import DiskKeeperCore
import Foundation
import Observation
import SwiftUI

/// A node paired with its name and size for the breadcrumb row.
struct Crumb: Identifiable, Equatable {
    let id: DiskNodeID
    let name: String
    let bytes: Int64
}

/// The old rectangles of nodes present in both layouts, for the zoom morph.
struct ZoomTransition: Equatable {
    let id: Int
    let from: [DiskNodeID: LayoutRect]
    let startedAt: Date
    static let duration: TimeInterval = 0.45
}

/// View model of the Disk Map: focus, mode, hover and selection over the shared `DiskIndexModel` tree.
/// The map is a viewer (PLAN invariant 12): this type has no route to cleanup.
@MainActor @Observable
final class DiskMapModel {
    enum Mode: String, CaseIterable { case strata, tiles }
    enum ColorBy: String, CaseIterable { case category, age }

    private(set) var mode: Mode = .strata
    private(set) var colorBy: ColorBy = .category
    private(set) var filterText = ""
    private(set) var focus: DiskNodeID?
    private(set) var layout: DiskMapLayout?
    private(set) var overlay: DiskMapOverlay?
    private(set) var paints: [ElementPaint] = []
    /// Element ids matching the filter; `nil` when no filter is set (nothing is dimmed).
    private(set) var matchingElements: Set<Int>?
    private(set) var hoveredElement: Int?
    private(set) var tooltipElement: Int?
    private(set) var tooltipAnchor: CGPoint = .zero
    private(set) var transition: ZoomTransition?
    private(set) var hasScanItems = false
    /// The tree the layout was computed from (adopted from the index in `treeChanged()`).
    private(set) var tree: DiskTree?
    private var selection: DiskNodeID?

    @ObservationIgnored let index: DiskIndexModel
    @ObservationIgnored private let scanItems: @MainActor () -> [ScanItem]
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let debounce: Duration
    @ObservationIgnored private let tooltipDelay: Duration
    @ObservationIgnored private let announce: @MainActor (String) -> Void
    @ObservationIgnored private var treeGeneration = -1
    @ObservationIgnored private var viewportSize: CGSize?
    @ObservationIgnored private(set) var layoutToken = 0
    @ObservationIgnored private var overlayToken = 0
    @ObservationIgnored private var transitionCounter = 0
    @ObservationIgnored private var lastHoverPoint: CGPoint = .zero
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private var dwellTask: Task<Void, Never>?
    @ObservationIgnored private(set) var layoutTask: Task<Void, Never>?
    @ObservationIgnored private(set) var overlayTask: Task<Void, Never>?
    /// Layout requests started (tests assert that hovering never starts one).
    @ObservationIgnored private(set) var layoutRequestCount = 0

    init(index: DiskIndexModel, scanItems: @escaping @MainActor () -> [ScanItem], now: @escaping () -> Date = Date.init,
         debounce: Duration = .milliseconds(50), tooltipDelay: Duration = .milliseconds(300),
         announce: @escaping @MainActor (String) -> Void = DiskMapModel.postAnnouncement) {
        self.index = index
        self.scanItems = scanItems
        self.now = now
        self.debounce = debounce
        self.tooltipDelay = tooltipDelay
        self.announce = announce
    }

    // MARK: Derived

    var focusID: DiskNodeID? { tree.map { focus ?? $0.rootNodeID } }
    var selectedNode: DiskNodeID? { selection ?? focusID }

    var rootName: String { tree.map { Self.scopeName($0.scope, rootPath: $0.rootPath) } ?? "" }

    static func scopeName(_ scope: DiskIndexer.Scope, rootPath: String) -> String {
        switch scope {
        case .home: DiskMapCopy.scopeHome
        case .fullDisk: DiskMapCopy.scopeFullDisk
        case .folder(let p): (p as NSString).lastPathComponent.isEmpty ? p : (p as NSString).lastPathComponent
        }
    }

    var breadcrumbs: [Crumb] {
        guard let tree, let f = focusID else { return [] }
        return (tree.ancestors(of: f) + [f]).map { id in
            Crumb(id: id, name: DiskMapLabels.title(of: id, tree: tree, rootName: rootName),
                  bytes: tree.node(id).allocatedBytes)
        }
    }

    var inspector: InspectorInfo? {
        guard let tree, let f = focusID, let n = selectedNode else { return nil }
        return DiskMapInspector.info(tree: tree, node: n, focus: f, overlay: overlay, rootName: rootName)
    }

    var axRows: [AXRow] {
        guard let tree, let layout else { return [] }
        return DiskMapAccessibility.rows(layout: layout, tree: tree, selection: selectedNode, overlay: overlay,
                                         rootName: rootName)
    }

    /// What the right-click menu acts on: the hovered element (aggregates act on their parent directory).
    struct ContextTarget: Equatable {
        let node: DiskNodeID
        let revealPath: String
        let canZoom: Bool
    }

    var contextTarget: ContextTarget? {
        guard let tree, let layout, let h = hoveredElement, layout.elements.indices.contains(h) else { return nil }
        switch layout.elements[h].kind {
        case .node(let id):
            let node = tree.node(id)
            let revealID = (node.flags.contains(.smallItems) ? node.parent : nil) ?? id
            return ContextTarget(node: id, revealPath: tree.path(of: revealID),
                                 canZoom: id != focusID && DiskMapKeyboard.canZoom(into: id, tree: tree))
        case .aggregate(let parent, _, _):
            return ContextTarget(node: parent, revealPath: tree.path(of: parent), canZoom: false)
        }
    }

    /// Why the tree may be missing parts, for the info chip.
    var incompleteNote: String? {
        guard let stats = tree?.stats, !stats.isComplete else { return nil }
        if stats.issueCount > 0 { return DiskMapCopy.incompleteUnreadable(Formatting.count(stats.issueCount)) }
        return DiskMapCopy.incompleteBudget
    }

    /// Layers present in the current layout, for the legend (category mode).
    var presentLayers: [StrataLayer] {
        var seen = Set<StrataLayer>()
        for p in paints { if case .layer(let l) = p.fill, p.opacity == 1 { seen.insert(l) } }
        return StrataLayer.allCases.filter { seen.contains($0) }
    }

    var hasProtectedElements: Bool { paints.contains { $0.hatched } }

    // MARK: Inputs

    func setMode(_ m: Mode) {
        guard m != mode else { return }
        mode = m
        clearPointer()
        requestLayout(animated: false)
    }

    func setColorBy(_ c: ColorBy) {
        guard c != colorBy else { return }
        colorBy = c
        recomputePaints()
    }

    func setFilterText(_ t: String) {
        guard t != filterText else { return }
        filterText = t
        recomputeMatches()
    }

    func viewportChanged(_ size: CGSize) {
        guard size.width >= 120, size.height >= 80, size != viewportSize else { return }
        viewportSize = size
        debounceTask?.cancel()
        if layout == nil {
            requestLayout(animated: false)
        } else {
            let wait = debounce
            debounceTask = Task { [weak self] in
                try? await Task.sleep(for: wait)
                guard !Task.isCancelled else { return }
                self?.requestLayout(animated: false)
            }
        }
    }

    /// Adopts a new index tree: keeps the focus when its path still exists, otherwise returns to the root.
    func treeChanged() {
        guard let new = index.tree else { return }
        guard treeGeneration != index.generation || tree == nil else { return }
        let oldPath = tree.flatMap { old in focus.map { old.path(of: $0) } }
        tree = new
        treeGeneration = index.generation
        clearPointer()
        selection = nil
        transition = nil
        var newFocus: DiskNodeID?
        if let oldPath, let n = new.lookup(path: oldPath), n != new.rootNodeID,
           new.path(of: n).caseInsensitiveCompare(oldPath) == .orderedSame, DiskMapKeyboard.canZoom(into: n, tree: new) {
            newFocus = n
        }
        focus = newFocus
        rebuildOverlay()
        requestLayout(animated: false)
    }

    /// The scan changed (new items or a new run): rebuild the overlay off the main thread.
    func scanChanged() { rebuildOverlay() }

    // MARK: Pointer

    func hover(_ point: CGPoint?) {
        guard let layout, let point else { setHover(nil); return }
        lastHoverPoint = point
        setHover(layout.element(at: LayoutPoint(point))?.id)
    }

    private func setHover(_ id: Int?) {
        guard id != hoveredElement else { return }
        hoveredElement = id
        dwellTask?.cancel()
        tooltipElement = nil
        guard id != nil else { return }
        let delay = tooltipDelay
        dwellTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, self.hoveredElement == id else { return }
            self.tooltipAnchor = self.lastHoverPoint
            self.tooltipElement = id
        }
    }

    private func clearPointer() {
        dwellTask?.cancel()
        hoveredElement = nil
        tooltipElement = nil
    }

    /// Selects the node under `point`; a second click on the selected directory zooms into it.
    func click(_ point: CGPoint) {
        guard let layout, let tree, let el = layout.element(at: LayoutPoint(point)),
              case .node(let id) = el.kind else { return }
        if id == selection, id != focusID, DiskMapKeyboard.canZoom(into: id, tree: tree) {
            zoom(into: id)
        } else {
            select(id)
        }
    }

    func select(_ id: DiskNodeID) {
        guard let tree, id.raw >= 0, Int(id.raw) < tree.nodeCount else { return }
        selection = id == focusID ? nil : id
        announceSelection(id)
    }

    // MARK: Zoom

    func zoom(into node: DiskNodeID) {
        guard let tree, Int(node.raw) < tree.nodeCount, node != focusID,
              DiskMapKeyboard.canZoom(into: node, tree: tree) else { return }
        focus = node == tree.rootNodeID ? nil : node
        selection = nil
        clearPointer()
        requestLayout(animated: true)
    }

    @discardableResult
    func zoomOut() -> Bool {
        guard let tree, let f = focusID, let parent = tree.node(f).parent else { return false }
        focus = parent == tree.rootNodeID ? nil : parent
        selection = f
        clearPointer()
        requestLayout(animated: true)
        return true
    }

    func zoom(toCrumb node: DiskNodeID) {
        guard let tree, let f = focusID, node != f, tree.ancestors(of: f).contains(node) else { return }
        focus = node == tree.rootNodeID ? nil : node
        selection = nil
        clearPointer()
        requestLayout(animated: true)
    }

    /// Keyboard: arrows move, Return zooms, Esc goes up. Returns whether the key was used.
    func handleKey(_ key: MapKey) -> Bool {
        guard let layout, let tree else { return false }
        switch DiskMapKeyboard.action(layout: layout, tree: tree, selected: selection, key: key) {
        case .none: return false
        case .select(let id): select(id); return true
        case .zoomIn(let id): zoom(into: id); return true
        case .zoomOut: return zoomOut()
        }
    }

    // MARK: Layout

    private func requestLayout(animated: Bool) {
        guard let tree, let size = viewportSize, let focusID else { return }
        layoutToken += 1
        layoutRequestCount += 1
        let token = layoutToken
        var from: [DiskNodeID: LayoutRect]?
        if animated, let old = layout {
            var rects: [DiskNodeID: LayoutRect] = [:]
            for el in old.elements { if case .node(let id) = el.kind { rects[id] = el.rect } }
            from = rects
        }
        let request = DiskMapLayoutRequest(tree: tree, focus: focusID, size: size, mode: mode)
        layoutTask = Task { [weak self] in
            let result = await DiskMapLayoutWorker.computeOffMain(request)
            self?.apply(result, token: token, from: from)
        }
    }

    /// Stale results (an older token) are dropped.
    func apply(_ result: DiskMapLayout, token: Int, from: [DiskNodeID: LayoutRect]?) {
        guard token == layoutToken else { return }
        layout = result
        if let from {
            transitionCounter += 1
            let id = transitionCounter
            transition = ZoomTransition(id: id, from: from, startedAt: Date())
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                if self?.transition?.id == id { self?.transition = nil }
            }
        } else {
            transition = nil
        }
        if let sel = selection, result.element(for: sel) == nil { selection = nil }
        clearPointer()
        recomputePaints()
    }

    // MARK: Overlay, paints, filter

    private func rebuildOverlay() {
        guard let tree else { return }
        overlayToken += 1
        let token = overlayToken
        let items = scanItems()
        hasScanItems = !items.isEmpty
        overlayTask = Task { [weak self] in
            let built = await Task.detached(priority: .userInitiated) { DiskMapOverlay.build(tree: tree, items: items) }.value
            guard let self, self.overlayToken == token else { return }
            self.overlay = built
            self.recomputePaints()
        }
    }

    private func recomputePaints() {
        guard let layout, let tree else { paints = []; matchingElements = nil; return }
        paints = DiskMapColoring.paints(layout: layout, tree: tree, overlay: overlay, colorBy: colorBy, now: now())
        recomputeMatches()
    }

    private func recomputeMatches() {
        let text = filterText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, let layout, let tree else { matchingElements = nil; return }
        let root = rootName
        var hits = Set<Int>()
        for el in layout.elements {
            guard case .node(let id) = el.kind else { continue }
            if DiskMapLabels.title(of: id, tree: tree, rootName: root).localizedStandardContains(text) { hits.insert(el.id) }
        }
        matchingElements = hits
    }

    // MARK: Test support

    func waitForLayout() async { await layoutTask?.value }
    func waitForOverlay() async { await overlayTask?.value }

    // MARK: Announcements

    private func announceSelection(_ id: DiskNodeID) {
        guard let tree, let f = focusID else { return }
        let node = tree.node(id), fnode = tree.node(f)
        let fraction = fnode.allocatedBytes > 0 ? Double(node.allocatedBytes) / Double(fnode.allocatedBytes) : 0
        announce(DiskMapCopy.nodeA11y(name: DiskMapLabels.title(of: id, tree: tree, rootName: rootName),
                                      size: Formatting.bytes(node.allocatedBytes),
                                      percent: DiskMapCopy.percentNumber(fraction),
                                      of: DiskMapLabels.title(of: f, tree: tree, rootName: rootName)))
    }

    /// Posts only when VoiceOver is running.
    static func postAnnouncement(_ text: String) {
        guard NSWorkspace.shared.isVoiceOverEnabled else { return }
        AccessibilityNotification.Announcement(text).post()
    }
}
