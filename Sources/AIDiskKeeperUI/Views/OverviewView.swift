import DiskKeeperCore
import SwiftUI

/// Overview *is* the Care Scan: the hero, the whole-disk strata bar, one tile per module and the biggest wins.
struct OverviewView: View {
    let care: CareScanModel
    let scan: ScanViewModel
    let storage: StorageModel
    let cleanup: CleanupCoordinator
    let selection: SelectionModel
    var open: (SidebarSelection) -> Void
    var inspect: (ScanItem) -> Void
    var showWarnings: () -> Void

    private let tilesAnchor = "overview.tiles"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: ADKTheme.Spacing.lg) {
                    header
                    CareHero(model: care, storage: storage, showFirstRunNote: care.phase == .before && care.lastFinishedAt == nil && care.index.tree == nil,
                             onReview: { withAnimation { proxy.scrollTo(tilesAnchor, anchor: .top) } },
                             onCleanSafe: { care.cleanSafeOnly(using: cleanup, selection: selection) })
                    OverviewStrata(storage: storage, scan: scan, care: care)
                    OverviewModuleTiles(care: care, scan: scan, open: open).id(tilesAnchor)
                    if !care.biggestWins.isEmpty {
                        BiggestWinsList(wins: care.biggestWins,
                                        seeAll: { if let target = BiggestWins.destination(for: care.biggestWins) { open(target) } },
                                        inspect: inspect)
                    }
                    if !care.warnings.isEmpty, care.phase == .results || care.phase == .stopped {
                        Button(action: showWarnings) {
                            Label(OverviewCopy.unreadable(care.warnings.count), systemImage: "exclamationmark.circle")
                        }.buttonStyle(.link)
                    }
                    if care.phase == .before { EmptyStateView() }
                }
                .padding(ADKTheme.Spacing.xl)
            }
        }
        .task { storage.refresh() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(OverviewCopy.title).font(ADKTheme.Font.largeTitle).foregroundStyle(.adkText)
            Spacer()
            if let finished = care.lastFinishedAt, care.phase != .scanning {
                TimelineView(.periodic(from: .now, by: 30)) { _ in
                    Text(OverviewCopy.lastScan(Formatting.relative(finished))).font(.caption).foregroundStyle(.adkText3)
                }
            }
        }
    }
}
