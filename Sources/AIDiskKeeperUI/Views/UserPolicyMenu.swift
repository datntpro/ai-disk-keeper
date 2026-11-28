import DiskKeeperCore
import SwiftUI

/// "Never show this item", "Mark as Review/Keep" and "Reset override". Only stricter tiers are offered.
@MainActor
enum UserPolicyMenu {
    @ViewBuilder static func buttons(item: ScanItem, settings: SettingsModel) -> some View {
        Button(loc("rules.neverShow", "Never show this item")) { settings.ignoreItem(item.id) }
        ForEach(UserPolicyChoices.offered(for: item.tier), id: \.self) { tier in
            Button(tier == .review ? loc("rules.markReview", "Mark as Review") : loc("rules.markKeep", "Mark as Keep")) {
                settings.overrideTier(of: item, to: tier)
            }
        }
        if settings.hasOverride(item) {
            Button(loc("rules.resetOverride", "Reset override")) {
                settings.resetOverride(settings.settings.tierOverrides[item.id] != nil ? item.id : item.ruleID)
            }
        }
    }

    @ViewBuilder static func section(item: ScanItem, settings: SettingsModel) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(loc("rules.section", "Your rules")).font(.headline)
            HStack { buttons(item: item, settings: settings) }
            Text(loc("settings.changesApplyNextScan", "Changes apply to the next scan.")).font(.caption).foregroundStyle(.secondary)
        }
    }
}
