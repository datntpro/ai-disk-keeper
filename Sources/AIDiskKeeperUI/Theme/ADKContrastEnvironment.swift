import SwiftUI

private struct ADKIncreasedContrastKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True under macOS Increase Contrast. Components draw a 1 px `lineStrong` border when it is set.
    /// `adkThemeRoot()` sets it from the system; previews and tests may override it.
    var adkIncreasedContrast: Bool {
        get { self[ADKIncreasedContrastKey.self] }
        set { self[ADKIncreasedContrastKey.self] = newValue }
    }
}

private struct ADKThemeRoot: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content.environment(\.adkIncreasedContrast, contrast == .increased)
    }
}

extension View {
    /// Apply once at the root of a window so every Strata component sees the Increase Contrast setting.
    func adkThemeRoot() -> some View { modifier(ADKThemeRoot()) }
}
