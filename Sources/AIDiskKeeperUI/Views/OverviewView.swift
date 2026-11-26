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
                    if care.startFailed {
                        StateView(kind: .error, symbol: "exclamationmark.triangle", title: StateCopy.errorScan, message: "",
                                  actions: [StateAction(title: StateCopy.retry) { care.start() }])
                            .frame(maxWidth: .infinity)
                    }
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
                    if !care.startFailed, !care.warnings.isEmpty, care.phase == .results || care.phase == .stopped {
                        partialBanner
                    }
                    if care.phase == .before { EmptyStateView() }
                }
                .padding(ADKTheme.Spacing.xl)
            }
        }
        .task { storage.refresh() }
    }

    /// `state.partial.*`: the scan finished but some folders couldn't be read.
    private var partialBanner: some View {
        HStack(alignment: .top, spacing: ADKTheme.Spacing.md) {
            Image(systemName: "exclamationmark.circle").foregroundStyle(.adkReviewInk).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(StateCopy.partialTitle(care.warnings.count)).font(.callout.weight(.semibold))
                Text(StateCopy.partialBody).font(.caption).foregroundStyle(.adkText2)
            }
            Spacer()
            Button(StateCopy.partialShow, action: showWarnings)
        }
        .padding(ADKTheme.Spacing.md)
        .background(.adkReviewSoft, in: RoundedRectangle(cornerRadius: ADKTheme.Radius.lg))
        .accessibilityElement(children: .contain)
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
