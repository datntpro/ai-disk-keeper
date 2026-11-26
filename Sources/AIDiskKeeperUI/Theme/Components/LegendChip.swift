import SwiftUI

/// A colour dot with its label. The label always carries the meaning; the dot is only a key.
struct LegendChip: View {
    let color: Color
    let label: String

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8).accessibilityHidden(true)
            Text(label).font(.caption).foregroundStyle(.adkText2)
        }
        .accessibilityElement(children: .combine)
    }
}
