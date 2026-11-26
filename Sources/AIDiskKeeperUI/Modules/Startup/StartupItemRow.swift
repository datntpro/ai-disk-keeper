import DiskKeeperCore
import SwiftUI

/// The cells of one table row.
struct StartupItemCell: View {
    let item: StartupItem

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.displayName).lineLimit(1).truncationMode(.middle)
            if let program = item.program {
                HStack(spacing: 4) {
                    PathText(program)
                    if item.programState == .missing {
                        Text(StartupCopy.missingMark).font(.caption).foregroundStyle(.adkReviewInk).fixedSize()
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct StartupDomainPill: View {
    let domain: StartupItem.Domain

    var body: some View {
        Text(StartupCopy.domain(domain))
            .font(.caption.weight(.medium)).foregroundStyle(.adkText2)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(.adkSunken, in: Capsule())
            .lineLimit(1)
    }
}

struct StartupStatusCell: View {
    let item: StartupItem
    let model: StartupItemsModel

    var body: some View {
        HStack(spacing: ADKTheme.Spacing.sm) {
            if item.isRemovable { TierBadge(tier: .safe, compact: true) }
            Text(StartupCopy.status(item))
                .foregroundStyle(item.label == nil ? .adkReviewInk : .adkText2)
                .lineLimit(2)
            if item.isHomebrewService, item.label != nil {
                Button(StartupCopy.copyCommand) { model.copyBrewCommand(item) }
                    .buttonStyle(.borderless).font(.caption)
            } else if !item.isRemovable {
                Button(loc("action.reveal", "Reveal in Finder")) { model.revealPlist(item) }
                    .buttonStyle(.borderless).font(.caption)
            }
        }
    }
}
