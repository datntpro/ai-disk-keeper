import SwiftUI

/// The "before" footnote under the Care Scan hero. The polished first-run explainer is T46's.
struct EmptyStateView: View {
    var body: some View {
        Text(loc("empty.readOnlyNote", "Scanning is read-only. AI Disk Keeper only looks: nothing is changed until you review a cleanup plan and confirm it."))
            .font(.callout).foregroundStyle(.adkText3)
            .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
    }
}
