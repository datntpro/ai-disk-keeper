import SwiftUI

/// Bottom bar for a selection: size, count, a hint and the one primary action.
struct SelectionActionBar: View {
    let bytes: Int64
    let countLabel: String
    var hint: String?
    let primaryTitle: String
    let count: Int
    let action: () -> Void

    var body: some View {
        HStack(spacing: ADKTheme.Spacing.md) {
            SizeText(bytes, qualifier: .upTo).font(.headline)
            Text(countLabel).foregroundStyle(.adkText2)
            if let hint { Text(hint).foregroundStyle(.adkText3).lineLimit(1) }
            Spacer()
            Button(primaryTitle, action: action)
                .buttonStyle(.borderedProminent)
                .tint(.adkAccent)
                .disabled(count == 0)
        }
        .font(.callout)
        .padding(.horizontal, ADKTheme.Spacing.lg).padding(.vertical, ADKTheme.Spacing.md)
        .background(.bar)
        .overlay(alignment: .top) { Rectangle().fill(.adkLine).frame(height: ADKTheme.hairline) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(SizeText.string(bytes, .upTo) + ", " + countLabel)
    }
}
