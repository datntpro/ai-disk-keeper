import DiskKeeperCore
import Foundation

/// Wording for the unavailable-simulator items (a code scanner, so not in the rule JSON).
enum DevToolsTexts: Sendable {
    nonisolated static func text(for item: ScanItem) -> ScannerTexts.Text? {
        guard item.ruleID == "tool.devtools.simulator.unavailable" else { return nil }
        return ScannerTexts.Text(name: nil, explanation: explanation(runtime: runtime(of: item)))
    }

    /// The runtime in `Name (iOS 17.5)`; empty when the name has no suffix.
    nonisolated static func runtime(of item: ScanItem) -> String {
        guard item.displayName.hasSuffix(")"), let open = item.displayName.lastIndex(of: "(") else { return "" }
        return String(item.displayName[item.displayName.index(after: open)..<item.displayName.index(before: item.displayName.endIndex)])
    }

    nonisolated static func explanation(runtime: String) -> String {
        loc("devtools.simulator.explain",
            "A simulator for \(runtime), which is no longer installed, so it can't start. Deleting it with simctl removes the device and the apps and data inside it.")
    }
}
