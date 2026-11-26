import SwiftUI

/// A raised surface with a hairline border (a stronger one under Increase Contrast).
struct SectionCard<Content: View>: View {
    var padding: CGFloat = ADKTheme.Spacing.lg
    @ViewBuilder var content: Content
    @Environment(\.adkIncreasedContrast) private var increasedContrast

    var body: some View {
        content
            .padding(padding)
            .background(.adkSurface, in: RoundedRectangle(cornerRadius: ADKTheme.Radius.lg))
            .overlay {
                RoundedRectangle(cornerRadius: ADKTheme.Radius.lg)
                    .strokeBorder(increasedContrast ? .adkLineStrong : .adkLine, lineWidth: ADKTheme.hairline)
            }
    }
}
