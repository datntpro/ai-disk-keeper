import SwiftUI

/// The status item: the Strata glyph (template image) and, when the setting is on, the free space next to it.
struct MenuBarLabel: View {
    let model: MenuBarModel

    var body: some View {
        HStack(spacing: 4) {
            Image(nsImage: StrataGlyph.image())
            if let text = model.labelFreeText { Text(verbatim: text) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.labelAccessibility)
    }
}
