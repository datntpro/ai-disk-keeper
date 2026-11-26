import DiskKeeperCore
import SwiftUI

public struct RootView: View {
    let env: AppEnvironment
    @State private var scan: ScanViewModel
    @State private var suite: SuiteModel
    @State private var query = ItemQuery()
    @State private var inspectedID: ScanItem.ID?
    @State private var list = ItemListModel()
    @State private var showInspector = true
    @State private var cleanupSelection = SelectionModel()

    public init(env: AppEnvironment) {
        self.env = env
        _scan = State(initialValue: ScanViewModel(makeEngine: env.makeScanEngine))
        _suite = State(initialValue: SuiteModel(env: env))
    }

    /// The language revision is the view identity of the whole tree, so every `loc()` call re-runs after a switch.
    /// Model state lives in this view (outside the identity), so a language change keeps the scan results.
    public var body: some View {
        mainContent
            .adkThemeRoot()
            .tint(.adkAccent)
            .id(env.settings.languageRevision)
            .environment(\.locale, L10n.locale)
    }

    private var selection: SidebarSelection { suite.navigation.selection }

    private var context: ModuleContext {
        ModuleContext(env: env, scan: scan, suite: suite, scanSelection: cleanupSelection, list: list,
                      query: $query, inspectedID: $inspectedID)
    }

    private var mainContent: some View {
        let ctx = context
        return NavigationSplitView {
            SidebarView(ctx: ctx)
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 280)
        } detail: {
            VStack(spacing: 0) {
                content(ctx)
                Divider()
                ScanStatusBar(scan: scan)
            }
            .frame(minWidth: 560)
        }
        .inspector(isPresented: $showInspector) {
            inspector(ctx)
                .inspectorColumnWidth(min: 260, ideal: 300, max: 400)
        }
        .toolbar {
            ScanToolbar(scan: scan)
            CleanupToolbar(scan: scan, selection: cleanupSelection, holder: env.cleanup, onReview: startReview)
            ToolbarItem {
                Button { showInspector.toggle() } label: { Label(loc("toolbar.details", "Details"), systemImage: "sidebar.trailing") }
                    .help(loc("toolbar.details.help", "Show or hide the detail pane"))
                    .accessibilityLabel(loc("toolbar.details.a11y", "Toggle detail pane"))
            }
        }
        .frame(minWidth: 1040, minHeight: 540)
        .focusedSceneValue(\.scanActions, ScanActions(
            canStart: !scan.isScanning, canStop: scan.phase == .scanning || scan.phase == .starting,
            start: { scan.startScan() }, stop: { scan.cancelScan() }))
        .focusedSceneValue(\.suiteNavigation, SuiteNavigation(go: { suite.navigation.selection = SidebarSelection(module: $0) }))
        .onChange(of: suite.navigation.selection) { _, new in query.scope = new }
        .onChange(of: query) { _, _ in refreshList() }
        .onChange(of: scan.items.count) { _, _ in refreshList() }
        .onChange(of: scan.phase) { _, _ in refreshList() }
        .onChange(of: scan.scanGeneration) { _, _ in refreshList() }
        .onAppear { refreshList() }
        .onChange(of: scan.scanGeneration) { _, _ in inspectedID = nil }
        .onChange(of: scan.scanGeneration) { _, g in cleanupSelection.syncScanGeneration(g) }
        .sheet(isPresented: Binding(get: { suite.cleanup.isPresented },
                                    set: { if !$0 { suite.cleanup.dismiss() } })) {
            if let flow = suite.cleanup.flow {
                CleanupSheetContent(flow: flow, environment: env.pathEnvironment, coordinator: suite.cleanup)
                    .interactiveDismissDisabled(flow.isExecuting)
            }
        }
        .onChange(of: suite.cleanup.rescanRequests) { _, _ in scan.startScan() }
        .onChange(of: scan.phase) { _, phase in announce(phase) }
        .onExitCommand { if scan.isScanning { scan.cancelScan() } }
        .sheet(isPresented: Binding(get: { !env.settings.settings.hasCompletedOnboarding }, set: { _ in })) {
            OnboardingView(settings: env.settings,
                           onboarding: OnboardingModel(settings: env.settings) { scan.startScan() },
                           dismiss: {})
        }
    }

    @ViewBuilder private func content(_ ctx: ModuleContext) -> some View {
        if let id = selection.moduleID {
            ModuleRegistry.provider(for: id).makeDetail(ctx)
        } else if case .warnings = selection {
            WarningsView(warnings: scan.warnings)
        } else {
            ScopedItemListView(ctx: ctx, scopeName: scopeName)
        }
    }

    /// A module may bring its own inspector; otherwise the shared item inspector.
    @ViewBuilder private func inspector(_ ctx: ModuleContext) -> some View {
        if let id = selection.moduleID, let custom = ModuleRegistry.provider(for: id).makeInspector(ctx) {
            custom
        } else {
            ItemDetailView(item: inspectedID.flatMap { scan.item(id: $0) })
        }
    }

    private var scopeName: String? {
        switch selection {
        case .tool(let t): t.uiName
        case .category(let c): c.uiName
        default: nil
        }
    }

    private func startReview() {
        let selected = cleanupSelection.selectedItems(in: scan.items)
        suite.cleanup.review(selected) { trashed in
            scan.removeItems(trashed)
            cleanupSelection.deselectAll()
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
