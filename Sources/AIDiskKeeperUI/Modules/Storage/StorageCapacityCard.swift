import SwiftUI

struct StorageCapacityCard: View {
    let model: StorageModel

    var body: some View {
        SectionCard {
            VStack(alignment: .leading, spacing: ADKTheme.Spacing.md) {
                if let free = model.freeBytes {
                    HeroNumberText(loc("storage.free", "\(Formatting.bytes(free)) free"))
                }
                if let used = model.usedBytes, let total = model.totalBytes {
                    Text(loc("storage.usedOf", "\(Formatting.bytes(used)) of \(Formatting.bytes(total)) used"))
                        .foregroundStyle(.adkText2).monospacedDigit()
                }
                if let total = model.totalBytes {
                    StrataBar(segments: model.segments, total: total, free: model.strictFreeBytes,
                               unknownLabels: model.unknownSegmentLabels)
                    legend
                }
                VStack(alignment: .leading, spacing: ADKTheme.Spacing.xs) {
                    if let strict = model.strictFreeBytes {
                        Text(loc("storage.availableNow", "Available now, without macOS freeing anything: \(Formatting.bytes(strict))"))
                    }
                    if let purgeable = model.purgeableBytes {
                        HStack(spacing: ADKTheme.Spacing.sm) {
                            Text(loc("storage.purgeableLine",
                                     "Purgeable (estimate): \(Formatting.bytes(purgeable)) · macOS frees this on its own when it needs room"))
                            StatusPill(kind: .estimate)
                        }
                    }
                }
                .font(.caption).foregroundStyle(.adkText2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var legend: some View {
        HStack(spacing: ADKTheme.Spacing.md) {
            ForEach(model.segments) { LegendChip(color: $0.layer.color, label: $0.label) }
            LegendChip(color: .adkLine, label: loc("storage.layer.free", "Free"))
        }
    }
}
