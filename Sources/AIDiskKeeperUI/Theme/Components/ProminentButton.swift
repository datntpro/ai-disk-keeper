import SwiftUI

extension View {
    /// `.borderedProminent` tinted `adkAccent`, with the label in `adkOnAccent` so it keeps 4.5:1 in dark mode
    /// (the dark accent is light teal; the system's white label would fail).
    func adkProminentButton() -> some View {
        buttonStyle(.borderedProminent).tint(.adkAccent).foregroundStyle(.adkOnAccent)
    }
}
