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

/// "Go" menu actions: jump to a module by its ⌘-number.
struct SuiteNavigation {
    var go: (ModuleID) -> Void
}

struct SuiteNavigationKey: FocusedValueKey { typealias Value = SuiteNavigation }

extension FocusedValues {
    var suiteNavigation: SuiteNavigation? {
        get { self[SuiteNavigationKey.self] }
        set { self[SuiteNavigationKey.self] = newValue }
    }
}

public struct ScanCommands: Commands {
    @FocusedValue(\.scanActions) private var actions
    @FocusedValue(\.suiteNavigation) private var navigation

    public init() {}

    public var body: some Commands {
        CommandMenu(loc("menu.scan", "Scan")) {
            Button(loc("action.scan", "Scan")) { actions?.start() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(!(actions?.canStart ?? false))
            Button(loc("action.stop", "Stop")) { actions?.stop() }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(!(actions?.canStop ?? false))
        }
        CommandMenu(loc("menu.go", "Go")) {
            // ⌘1…⌘9 for the first nine enabled modules.
            ForEach(Array(ModuleRegistry.enabled().prefix(9).enumerated()), id: \.element.id) { index, module in
                Button(module.title) { navigation?.go(module.id) }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                    .disabled(navigation == nil)
            }
        }
    }
}
