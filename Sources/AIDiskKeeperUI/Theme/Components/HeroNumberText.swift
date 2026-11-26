import SwiftUI

/// The big number on Overview. A scaled metric, so it follows the user's text size even at 60 pt.
struct HeroNumberText: View {
    let text: String
    @ScaledMetric(relativeTo: .largeTitle) private var size: CGFloat = 60

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: size, weight: .thin))
            .monospacedDigit()
            .foregroundStyle(.adkText)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
    }
}
