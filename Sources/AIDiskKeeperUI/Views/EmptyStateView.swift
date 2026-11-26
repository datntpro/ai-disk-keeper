import SwiftUI

/// The first-run note under the Care Scan hero: what a scan is, and what it covers. The one primary
/// action ("Start Care Scan") lives in the hero.
struct EmptyStateView: View {
    @State private var showWhat = false

    var body: some View {
        VStack(alignment: .leading, spacing: ADKTheme.Spacing.sm) {
            Text(StateCopy.firstRunTitle).font(.headline).foregroundStyle(.adkText)
            Text(StateCopy.firstRunBody).font(.callout).foregroundStyle(.adkText3)
            Button(StateCopy.firstRunWhat) { showWhat.toggle() }
                .buttonStyle(.link)
                .popover(isPresented: $showWhat, arrowEdge: .bottom) {
                    Text(StateCopy.firstRunWhatBody).font(.callout).frame(width: 320, alignment: .leading)
                        .padding(ADKTheme.Spacing.lg)
                }
        }
        .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}
