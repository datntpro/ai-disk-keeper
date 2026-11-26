import DiskKeeperCore
import Foundation

/// Scanner-owned wording for items that have no rule behind them (virtual items). Each tool scanner adds one line
/// to `providers`; `RuleTexts` asks here first.
enum ScannerTexts {
    struct Text { var name: String?; var explanation: String? }
    static let providers: [@Sendable (ScanItem) -> Text?] = [
        { DevToolsTexts.text(for: $0) },
    ]

    static func text(for item: ScanItem) -> Text? {
        for p in providers { if let t = p(item) { return t } }
        return nil
    }
}
