import DiskKeeperCore
import SwiftUI

/// One tile per module that has something to show; each opens its screen.
struct OverviewModuleTiles: View {
    let care: CareScanModel
    let scan: ScanViewModel
    let open: (SidebarSelection) -> Void

    /// The modules to show: a summary exists, the screen is enabled (System junk has none), and Startup only
    /// when it found something.
    static func tiles(summaries: [CareModule: ModuleSummary], enabled: Set<ModuleID> = ModuleRegistry.enabledIDs) -> [CareModule] {
        CareModule.allCases.filter { module in
            guard let s = summaries[module] else { return false }
            if module == .startup, s.itemCount == 0 { return false }
            return OverviewTarget.moduleID(for: module).map(enabled.contains) ?? true
        }
    }

    func caption(_ module: CareModule, _ summary: ModuleSummary) -> String {
        switch module {
        case .aiTools:
            var bytesByTool: [ToolID: Int64] = [:]
            for item in scan.items where item.category == .aiToolData { bytesByTool[item.tool, default: 0] += item.sizeAllocated }
            let ranked = bytesByTool.sorted { ($0.value, $1.key.rawValue) > ($1.value, $0.key.rawValue) }.map(\.key.uiName)
            guard !ranked.isEmpty else { return OverviewCopy.tileItems(summary.itemCount) }
            return OverviewCopy.tileAITools(names: ranked.prefix(4).joined(separator: ", "),
                                            more: max(0, ranked.count - 4), items: summary.itemCount)
        case .largeOld: return OverviewCopy.tileLargeOld(summary.itemCount)
        case .duplicates: return OverviewCopy.tileDuplicates(care.duplicateGroupCount)
        case .apps: return OverviewCopy.tileApps(summary.itemCount)
        case .systemJunk: return OverviewCopy.tileSystemJunk
        case .worktrees, .modelsDocker, .startup: return OverviewCopy.tileItems(summary.itemCount)
        }
    }

    var body: some View {
        let shown = Self.tiles(summaries: care.summaries)
        if !shown.isEmpty {
            VStack(alignment: .leading, spacing: ADKTheme.Spacing.sm) {
                HStack(alignment: .firstTextBaseline) {
                    Text(OverviewCopy.modulesTitle).font(ADKTheme.Font.headline).foregroundStyle(.adkText)
                    Text(OverviewCopy.modulesCaption).font(.caption).foregroundStyle(.adkText3)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: ADKTheme.Spacing.md, alignment: .top)],
                          alignment: .leading, spacing: ADKTheme.Spacing.md) {
                    ForEach(shown, id: \.self) { module in
                        let summary = care.summaries[module] ?? ModuleSummary(module: module)
                        VStack(alignment: .leading, spacing: 4) {
                            ModuleTile(symbol: OverviewTarget.symbol(for: module), title: OverviewTarget.title(for: module),
                                       bytes: summary.totalBytes,
                                       tierSplit: [.safe: summary.safeBytes, .review: summary.reviewBytes, .keep: summary.keepBytes]) {
                                open(OverviewTarget.selection(for: module))
                            }
                            Text(caption(module, summary)).font(.caption).foregroundStyle(.adkText3)
                                .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4)
                        }
                    }
                }
            }
        }
    }
}
