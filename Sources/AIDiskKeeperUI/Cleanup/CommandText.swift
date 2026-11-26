import SwiftUI

/// The verbatim command of a tool-command item, in place of a path: monospaced, selectable, middle-truncated.
struct CommandText: View {
    let line: String
    let help: String?
    init(_ line: String, help: String? = nil) { self.line = line; self.help = help }

    var body: some View {
        Text(line)
            .font(ADKTheme.Font.path)
            .foregroundStyle(.adkText2)
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
            .help(help ?? line)
            .accessibilityLabel(line)
    }
}
