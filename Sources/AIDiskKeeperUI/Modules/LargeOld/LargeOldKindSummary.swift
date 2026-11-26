import DiskKeeperCore
import SwiftUI

/// Five cards, one per kind. Each is a toggle that narrows the table to that kind.
struct LargeOldKindSummary: View {
    let model: LargeOldModel

    var body: some View {
        HStack(spacing: ADKTheme.Spacing.md) {
            ForEach(LargeFileKind.allCases, id: \.self) { kind in card(kind) }
        }
    }

    private func card(_ kind: LargeFileKind) -> some View {
        let total = model.kindTotals[kind] ?? (bytes: 0, count: 0)
        let on = model.filters.kinds.contains(kind)
        return Button { model.toggleKind(kind) } label: {
            SectionCard {
                VStack(alignment: .leading, spacing: 2) {
                    Text(LargeOldCopy.kindPlural(kind)).font(.caption).foregroundStyle(.adkText3).lineLimit(1)
                    SizeText(total.bytes).font(.title2.weight(.light))
                    Text(LargeOldCopy.count(total.count)).font(.caption).foregroundStyle(.adkText3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .overlay {
                RoundedRectangle(cornerRadius: ADKTheme.Radius.lg).strokeBorder(.adkAccent, lineWidth: on ? 2 : 0)
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(LargeOldCopy.kindPlural(kind))
        .accessibilityValue(Text(verbatim: "\(Formatting.bytes(total.bytes)), \(LargeOldCopy.count(total.count))"))
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }
}
