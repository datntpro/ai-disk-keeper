import DiskKeeperCore
import SwiftUI

/// The drive's own health report. Read-only; "Wear" is the drive's estimate (Percentage Used), not a lifetime prediction.
struct StorageSSDCard: View {
    let model: SSDHealthModel

    var body: some View {
        SectionCard {
            VStack(alignment: .leading, spacing: ADKTheme.Spacing.sm) {
                Text(loc("ssd.title", "SSD health")).font(.headline)
                switch model.state {
                case .idle, .loading:
                    Text(loc("ssd.loading", "Reading drive health…")).foregroundStyle(.adkText2)
                case .unavailable:
                    Text(loc("ssd.unavailable", "Health data isn't available for this disk")).foregroundStyle(.adkText2)
                case .ready(let h, let since):
                    ready(h, since)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { model.refreshIfNeeded() }
    }

    @ViewBuilder private func ready(_ h: SSDHealth, _ since: UInt64?) -> some View {
        if h.needsAttention {
            Label(loc("ssd.warning", "The drive reports wear or a warning. Back up your Mac."), systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.adkReviewInk)
        }
        Grid(alignment: .leading, horizontalSpacing: ADKTheme.Spacing.lg, verticalSpacing: ADKTheme.Spacing.xs) {
            row(loc("ssd.written", "Data written"), written(h))
            row(loc("ssd.wear", "Wear"), "\(h.percentageUsed)%")
            row(loc("ssd.spare", "Spare"), "\(h.availableSparePercent)%")
            if let t = h.temperatureCelsius { row(loc("ssd.temperature", "Temperature"), "\(t) °C") }
            if let since {
                row(loc("ssd.sinceStartup", "Written since startup"), Formatting.bytes(Int64(clamping: since)))
            }
        }
        .monospacedDigit()
        Text(loc("ssd.note", "Wear is the drive's own estimate (Percentage Used). It is read-only; nothing is written to the drive."))
            .font(.caption).foregroundStyle(.adkText3)
    }

    private func written(_ h: SSDHealth) -> String {
        h.bytesWrittenSaturated ? loc("ssd.writtenHuge", "more than 9 EB") : Formatting.bytes(Int64(clamping: h.bytesWritten))
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.adkText2)
            Text(value)
        }
    }
}
