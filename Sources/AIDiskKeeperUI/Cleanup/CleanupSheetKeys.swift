import SwiftUI

/// The keyboard contract of the review sheet, as data so a test can pin it: Return never confirms (focus starts
/// on Cancel), ⌘⏎ does, Esc cancels. No cleanup button may take the system default-action key.
enum CleanupSheetKeys {
    enum Button: Sendable { case cancel, recheck, confirm }

    static let confirm = KeyboardShortcut(.return, modifiers: .command)
    static let cancel = KeyboardShortcut.cancelAction
    static let defaultFocus: Button = .cancel
}
