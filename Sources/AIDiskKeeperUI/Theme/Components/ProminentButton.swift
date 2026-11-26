import SwiftUI

extension View {
    /// Primary action button: `adkAccent` fill with the label in `adkOnAccent` (4.5:1 in both appearances).
    /// A custom style is required: AppKit draws `.borderedProminent` itself and ignores `foregroundStyle`,
    /// which left a white label on the light-teal dark accent (~1.9:1).
    func adkProminentButton() -> some View {
        buttonStyle(ADKProminentButtonStyle()).keyboardShortcut(.defaultAction)
    }
}

struct ADKProminentButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        configuration.label
            .font(.body.weight(.medium))
            .foregroundStyle(Color.adkOnAccent)
            .padding(.horizontal, controlSize == .small ? 8 : 12)
            .padding(.vertical, controlSize == .small ? 3 : 5)
            .background(shape.fill(configuration.isPressed ? Color.adkAccentHover : Color.adkAccent))
            .contentShape(shape)
            .opacity(isEnabled ? 1 : 0.4)
    }
}
