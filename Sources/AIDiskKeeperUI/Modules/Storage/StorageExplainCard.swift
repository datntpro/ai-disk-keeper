import DiskKeeperCore
import SwiftUI

/// "Why don't these numbers match Finder?" Collapsed by default; the texts are the Core explanations, in order.
struct StorageExplainCard: View {
    @State private var expanded = false

    static let order: [StorageExplanation] = [.whyNumbersDiffer, .systemData, .purgeable]

    var body: some View {
        SectionCard {
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: ADKTheme.Spacing.sm) {
                    Text(loc("storage.why.intro",
                             "Finder and System Settings count purgeable space and snapshots differently. Here is what each number means."))
                        .fontWeight(.medium)
                    ForEach(Self.order, id: \.self) { Text($0.uiText) }
                }
                .font(.callout).foregroundStyle(.adkText2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, ADKTheme.Spacing.sm)
            } label: {
                Text(loc("storage.why.title", "Why don't these numbers match Finder?")).font(.headline)
            }
        }
    }
}
