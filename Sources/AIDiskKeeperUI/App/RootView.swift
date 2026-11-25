import DiskKeeperCore
import SwiftUI

public struct RootView: View {
    let env: AppEnvironment
    @State private var scan: ScanViewModel
    @State private var selection: SidebarSelection = .overview
    @State private var query = ItemQuery()
    @State private var inspectedID: ScanItem.ID?
    @State private var list = ItemListModel()
    @State private var showInspector = true

    public init(env: AppEnvironment) {
        self.env = env
        _scan = State(initialValue: ScanViewModel(makeEngine: env.makeScanEngine))
    }

    public var body: some View {
        NavigationSplitView {
            SidebarView(scan: scan, selection: $selection)
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 280)
        } detail: {
            VStack(spacing: 0) {
                content
                Divider()
                ScanStatusBar(scan: scan)
            }
            .frame(minWidth: 560)
        }
        .inspector(isPresented: $showInspector) {
            ItemDetailView(item: inspectedID.flatMap { scan.item(id: $0) })
                .inspectorColumnWidth(min: 260, ideal: 300, max: 400)
        }
        .toolbar {
            ScanToolbar(scan: scan)
            ToolbarItem {
                Button { showInspector.toggle() } label: { Label(loc("toolbar.details", "Details"), systemImage: "sidebar.trailing") }
                    .help(loc("toolbar.details.help", "Show or hide the detail pane"))
                    .accessibilityLabel(loc("toolbar.details.a11y", "Toggle detail pane"))
            }
        }
        .frame(minWidth: 900, minHeight: 540)
        .focusedSceneValue(\.scanActions, ScanActions(
            canStart: !scan.isScanning, canStop: scan.phase == .scanning || scan.phase == .starting,
            start: { scan.startScan() }, stop: { scan.cancelScan() }))
        .onChange(of: selection) { _, new in query.scope = new }
        .onChange(of: query) { _, _ in refreshList() }
        .onChange(of: scan.items.count) { _, _ in refreshList() }
        .onChange(of: scan.phase) { _, _ in refreshList() }
        .onChange(of: scan.scanGeneration) { _, _ in refreshList() }
        .onAppear { refreshList() }
        .onChange(of: scan.scanGeneration) { _, _ in inspectedID = nil }
        .onChange(of: scan.phase) { _, phase in announce(phase) }
        .onExitCommand { if scan.isScanning { scan.cancelScan() } }
    }

    @ViewBuilder private var content: some View {
        switch selection {
        case .overview:
            OverviewView(scan: scan, inspect: { id in inspectedID = id }, showWarnings: { selection = .warnings })
        case .warnings:
            WarningsView(warnings: scan.warnings)
        case .tool, .category:
            ItemTableView(rows: list.rows, tierCounts: list.tierCounts, query: $query, inspectedID: $inspectedID)
        }
    }

    private func refreshList() { list.update(items: scan.items, query: query) }

    private func announce(_ phase: ScanViewModel.Phase) {
        let t = scan.totals.all
        switch phase {
        case .finished:
            AccessibilityNotification.Announcement(finishedAnnouncement(bytes: Formatting.bytes(t.allocatedBytes), count: t.itemCount)).post()
        case .cancelled:
            AccessibilityNotification.Announcement(loc("status.stopped", "Scan stopped. Results are partial.")).post()
        default: break
        }
    }
}
