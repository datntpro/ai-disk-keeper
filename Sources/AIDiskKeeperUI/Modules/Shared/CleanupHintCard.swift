import AppKit
import SwiftUI

/// Copyable commands for tools that can clean themselves. The app only shows them: it never runs them.
struct CleanupHintCard: View {
    let title: String
    /// `copyable == false` shows the command as plain text without a Copy button.
    let hints: [(command: String, copyable: Bool)]

    /// Puts exactly `command` on the general pasteboard.
    static func copy(_ command: String, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setString(command, forType: .string)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            ForEach(hints, id: \.command) { hint in
                let command = hint.command
                HStack(spacing: 8) {
                    Text(command).font(.caption.monospaced()).textSelection(.enabled)
                    if hint.copyable {
                        Button(BuildCachesCopy.copyCommand) { Self.copy(command) }
                            .controlSize(.small)
                            .accessibilityLabel(BuildCachesCopy.copyCommandA11y(command))
                    }
                }
            }
        }
    }
}
