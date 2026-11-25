import DiskKeeperCore
import SwiftUI

struct OverviewView<Slot: View>: View {
    let scan: ScanViewModel
    var inspect: (ScanItem.ID) -> Void
    var showWarnings: () -> Void
    @ViewBuilder var belowTierCards: () -> Slot

    var body: some View {
        if scan.phase == .idle {
            EmptyStateView { scan.startScan() }
        } else {
            let totals = scan.totals
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(L10n.tr("overview.totalFound", "Total found")).font(.headline)
                        Text(Formatting.bytes(totals.all.allocatedBytes)).font(.title.weight(.semibold))
                        if scan.result?.wasCancelled == true {
                            Text(L10n.tr("overview.partial", "(partial: scan stopped)")).font(.callout).foregroundStyle(.orange)
                        }
                        Spacer()
                        if let d = scan.lastScanFinishedAt, !scan.isScanning {
                            Text(L10n.tr("overview.lastScan", "Last scan \(Formatting.relative(d))")).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(RiskTier.allCases, id: \.self) { tier in
                            card(tier, totals.byTier[tier] ?? .zero)
                        }
                    }
                    belowTierCards()
                    if !scan.warnings.isEmpty {
                        Button(action: showWarnings) {
                            Label(L10n.tr("overview.unreadable", "\(scan.warnings.count) folders couldn't be read"), systemImage: "exclamationmark.circle")
                        }.buttonStyle(.link)
                    }
                    Text(L10n.tr("overview.largest", "Largest items")).font(.headline)
                    ForEach(top10(scan.items)) { item in
                        Button { inspect(item.id) } label: {
                            HStack {
                                Text(item.displayName).lineLimit(1)
                                TierBadge(tier: item.tier)
                                Spacer()
                                Text(Formatting.bytes(item.sizeAllocated)).monospacedDigit().foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(item.a11yLabel)
                    }
                }
                .padding()
            }
        }
    }

    private func top10(_ items: [ScanItem]) -> [ScanItem] {
        ItemQuery(scope: .overview).apply(to: items).prefix(10).map { $0 }
    }

    private func card(_ tier: RiskTier, _ t: UsageTotals) -> some View {
        let s = TierStyle.style(for: tier)
        return VStack(alignment: .leading, spacing: 6) {
            TierBadge(tier: tier)
            Text(Formatting.bytes(t.allocatedBytes)).font(.title2.weight(.semibold))
            Text(L10n.tr("overview.itemCount", "\(t.itemCount) items")).font(.caption).foregroundStyle(.secondary)
            Text(s.shortExplanation).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }
}

extension OverviewView where Slot == EmptyView {
    init(scan: ScanViewModel, inspect: @escaping (ScanItem.ID) -> Void, showWarnings: @escaping () -> Void) {
        self.init(scan: scan, inspect: inspect, showWarnings: showWarnings) { EmptyView() }
    }
}
