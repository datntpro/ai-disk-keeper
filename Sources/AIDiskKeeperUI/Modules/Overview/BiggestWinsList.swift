import DiskKeeperCore
import SwiftUI

/// The three biggest things this scan found, mixed tiers on purpose, each with why it is where it is.
enum BiggestWins {
    static let limit = 3

    /// Top `limit` by bytes, skipping an item that equals, sits inside or contains one already picked.
    static func top(_ items: [ScanItem], limit: Int = BiggestWins.limit) -> [ScanItem] {
        var picked: [ScanItem] = []
        for item in items.sorted(by: { ($0.sizeAllocated, $1.path) > ($1.sizeAllocated, $0.path) }) where item.sizeAllocated > 0 {
            if picked.contains(where: { overlaps($0.path, item.path) }) { continue }
            picked.append(item)
            if picked.count == limit { break }
        }
        return picked
    }

    private static func overlaps(_ a: String, _ b: String) -> Bool {
        a == b || a.hasPrefix(b + "/") || b.hasPrefix(a + "/")
    }

    /// "See all": AI data when the largest item is AI data, otherwise where the top item lives.
    static func destination(for wins: [ScanItem], enabled: Set<ModuleID> = ModuleRegistry.enabledIDs) -> SidebarSelection? {
        guard let top = wins.first else { return nil }
        return NavigationModel.destination(for: top.category, enabled: enabled)
    }

    /// The first sentence of the explanation.
    static func why(_ item: ScanItem) -> String {
        let text = item.explanation
        if let end = text.firstIndex(where: { $0 == "." || $0 == "。" }) { return String(text[...end]) }
        return text
    }
}

struct BiggestWinsList: View {
    let wins: [ScanItem]
    let seeAll: () -> Void
    let inspect: (ScanItem) -> Void

    var body: some View {
        SectionCard {
            VStack(alignment: .leading, spacing: ADKTheme.Spacing.md) {
                HStack {
                    Text(OverviewCopy.winsTitle).font(ADKTheme.Font.headline).foregroundStyle(.adkText)
                    Spacer()
                    Button(OverviewCopy.winsSeeAll, action: seeAll).buttonStyle(.link)
                }
                ForEach(wins) { item in
                    Button { inspect(item) } label: { row(item) }
                        .buttonStyle(.plain)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(item.a11yLabel)
                        .accessibilityAddTraits(.isButton)
                    if item.id != wins.last?.id { Divider() }
                }
            }
        }
    }

    private func row(_ item: ScanItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: ADKTheme.Spacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.uiDisplayName()).font(.body.weight(.medium)).foregroundStyle(.adkText).lineLimit(1)
                PathText(item.path)
                Text(BiggestWins.why(item)).font(.caption).foregroundStyle(.adkText2).lineLimit(2)
            }
            Spacer(minLength: ADKTheme.Spacing.md)
            TierBadge(tier: item.tier)
            SizeText(item.sizeAllocated).font(.body.weight(.semibold)).foregroundStyle(.adkText)
        }
        .contentShape(Rectangle())
    }
}
