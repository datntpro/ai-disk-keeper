import SwiftUI

struct ScanActions {
    var canStart: Bool
    var canStop: Bool
    var start: () -> Void
    var stop: () -> Void
}

struct ScanActionsKey: FocusedValueKey { typealias Value = ScanActions }

extension FocusedValues {
    var scanActions: ScanActions? {
        get { self[ScanActionsKey.self] }
        set { self[ScanActionsKey.self] = newValue }
    }
}

public struct ScanCommands: Commands {
    @FocusedValue(\.scanActions) private var actions

    public init() {}

    public var body: some Commands {
        CommandMenu(L10n.tr("menu.scan", "Scan")) {
            Button(L10n.tr("action.scan", "Scan")) { actions?.start() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(!(actions?.canStart ?? false))
            Button(L10n.tr("action.stop", "Stop")) { actions?.stop() }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(!(actions?.canStop ?? false))
        }
    }
}
