import AppKit

/// The four looks the palette resolves: light/dark, each with the Increase Contrast variant.
enum ADKAppearance: CaseIterable, Sendable {
    case light, dark, highContrastLight, highContrastDark

    init(_ appearance: NSAppearance) {
        let best = appearance.bestMatch(from: [.accessibilityHighContrastDarkAqua, .accessibilityHighContrastAqua,
                                               .darkAqua, .aqua])
        self.init(name: best ?? .aqua)
    }

    /// Pure mapping from an appearance name. (`NSAppearance(named:)` hands back the plain variant for the high
    /// contrast names when the system setting is off, so this is the testable seam.)
    init(name: NSAppearance.Name) {
        switch name {
        case .darkAqua: self = .dark
        case .accessibilityHighContrastAqua: self = .highContrastLight
        case .accessibilityHighContrastDarkAqua: self = .highContrastDark
        default: self = .light
        }
    }

    var isDark: Bool { self == .dark || self == .highContrastDark }
    var isHighContrast: Bool { self == .highContrastLight || self == .highContrastDark }
}
