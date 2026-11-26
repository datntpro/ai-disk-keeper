import DiskKeeperCore
import Foundation
import os

/// The loaded rules' translations, readable from any isolation (item queries run off the main actor).
/// `AppEnvironment` installs the index once the rules are loaded; until then English is used.
public enum RuleTexts {
    private static let index = OSAllocatedUnfairLock(initialState: RuleTextIndex.empty)
    public static var current: RuleTextIndex { index.withLock { $0 } }
    public static func install(_ new: RuleTextIndex) { index.withLock { $0 = new } }
}

extension ScanItem {
    /// Rule explanation in the active language (English when the rule has no translation).
    func uiExplanation(_ idx: RuleTextIndex = RuleTexts.current) -> String {
        if let e = ScannerTexts.text(for: self)?.explanation { return e }
        return idx.explanation(ruleID: ruleID, languages: [L10n.languageCode]) ?? explanation
    }

    /// The rule title in the active language when the title *is* the item's name (`match.kind == .self`);
    /// file and folder names are data and never translated.
    func uiDisplayName(_ idx: RuleTextIndex = RuleTexts.current) -> String {
        if let n = ScannerTexts.text(for: self)?.name { return n }
        guard idx.titleIsItemName(ruleID: ruleID),
              let title = idx.title(ruleID: ruleID, languages: [L10n.languageCode]) else { return displayName }
        return title
    }

    func uiNameWithProject(_ idx: RuleTextIndex = RuleTexts.current) -> String {
        let name = uiDisplayName(idx)
        if let p = project { return "\(name) · \(p.displayName)" }
        return name
    }
}
