import SwiftUI

/// The bottom/top bar background. Material normally; a solid surface plus a hairline under
/// Reduce Transparency. This file is the only place allowed to use `.bar` or a material.
private struct ADKBarBackground: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(Color.adkSurface)
        } else {
            content.background(.bar)
        }
    }
}

extension View {
    /// Replaces `.background(.bar)`.
    func adkBarBackground() -> some View { modifier(ADKBarBackground()) }
}
