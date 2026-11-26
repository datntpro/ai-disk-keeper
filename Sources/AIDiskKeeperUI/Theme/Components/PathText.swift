import SwiftUI

/// A file path: monospaced, middle-truncated, selectable. VoiceOver reads the full path.
struct PathText: View {
    let path: String
    init(_ path: String) { self.path = path }

    var body: some View {
        Text(path)
            .font(ADKTheme.Font.path)
            .foregroundStyle(.adkText2)
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
            .accessibilityLabel(path)
    }
}
