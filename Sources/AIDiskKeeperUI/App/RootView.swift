import DiskKeeperCore
import SwiftUI

public struct RootView: View {
    let env: AppEnvironment
    @State private var scan: ScanViewModel
    @State private var selection: SidebarSelection = .overview
    @State private var query = ItemQuery()
    @State private var inspectedID: ScanItem.ID?

    public init(env: AppEnvironment) {
        self.env = env
        _scan = State(initialValue: ScanViewModel(makeEngine: env.makeScanEngine))
    }

    public var body: some View {
        NavigationSplitView {
            SidebarView(scan: scan, selection: $selection)
                .navigationSplitViewColumnWidth(min: 200, ideal: 230)
        } content: {
            VStack(spacing: 0) {
                content
                Divider()
                ScanStatusBar(scan: scan)
            }
            .navigationSplitViewColumnWidth(min: 380, ideal: 560)
        } detail: {
            ItemDetailView(item: inspectedID.flatMap { scan.item(id: $0) })
                .navigationSplitViewColumnWidth(min: 260, ideal: 320)
        }
        .toolbar { ScanToolbar(scan: scan) }
        .frame(minWidth: 900, minHeight: 540)
        .focusedSceneValue(\.scanActions, ScanActions(
            canStart: !scan.isScanning, canStop: scan.phase == .scanning || scan.phase == .starting,
            start: { scan.startScan() }, stop: { scan.cancelScan() }))
        .onChange(of: selection) { _, new in query.scope = new }
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
            ItemTableView(items: scan.items, query: $query, inspectedID: $inspectedID)
        }
    }

    private func announce(_ phase: ScanViewModel.Phase) {
        let t = scan.totals.all
        switch phase {
        case .finished:
            AccessibilityNotification.Announcement("Scan finished: \(Formatting.bytes(t.allocatedBytes)) in \(t.itemCount) items").post()
        case .cancelled:
            AccessibilityNotification.Announcement("Scan stopped. Results are partial.").post()
        default: break
        }
    }
}
