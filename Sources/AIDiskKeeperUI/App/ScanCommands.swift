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
        CommandMenu("Scan") {
            Button("Scan") { actions?.start() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(!(actions?.canStart ?? false))
            Button("Stop") { actions?.stop() }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(!(actions?.canStop ?? false))
        }
    }
}
