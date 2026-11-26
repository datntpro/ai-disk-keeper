import AppKit
import SwiftUI

/// The compact volume gauge in the sidebar footer. Hidden until the first measurement, so it never shows zeros.
struct StorageGauge: View {
    let model: StorageModel
    var onSelect: () -> Void = {}

    var body: some View {
        if let free = model.freeBytes, let used = model.usedBytes, let total = model.totalBytes, let fraction = model.usedFraction {
            let percent = Int((fraction * 100).rounded())
            Button(action: onSelect) {
                VStack(alignment: .leading, spacing: ADKTheme.Spacing.xs) {
                    Gauge(value: fraction) { EmptyView() }
                        .gaugeStyle(.accessoryLinearCapacity)
                        .tint(fraction >= 0.9 ? .adkReview : .adkAccent)
                    HStack {
                        Text(model.volumeName).font(.caption.weight(.medium))
                        Spacer()
                        Text(loc("storage.free", "\(Formatting.bytes(free)) free")).font(.caption).monospacedDigit()
                    }
                    Text(loc("storage.usedOf", "\(Formatting.bytes(used)) of \(Formatting.bytes(total)) used"))
                        .font(.caption2).foregroundStyle(.adkText3).monospacedDigit()
                }
                .padding(.horizontal, ADKTheme.Spacing.lg).padding(.vertical, ADKTheme.Spacing.md)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(loc("storage.gauge.a11y", "\(model.volumeName), \(Formatting.bytes(free)) free, \(Formatting.count(percent)) percent used"))
            .accessibilityAddTraits(.isButton)
        }
    }
}
