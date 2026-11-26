import SwiftUI

/// The status item: one template image drawn by `MenuBarLabelRenderer` (glyph, and the metrics the user put in the bar).
/// With nothing extra in the bar it is exactly the T47 item.
struct MenuBarLabel: View {
    let monitor: SystemMonitorModel

    var body: some View {
        Image(nsImage: monitor.labelImage)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(monitor.labelAccessibility)
    }
}
