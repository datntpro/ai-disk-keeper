import DiskKeeperCore
import Foundation
import Observation
import SwiftUI

/// Which sidebar row is selected, and the "Review in list" jumps between modules.
@MainActor @Observable
public final class NavigationModel {
    public var selection: SidebarSelection = .overview

    public init() {}

    /// Jumps to the module that lists `item`, clears the search, makes sure the item's tier is visible and
    /// inspects it.
    public func show(item: ScanItem, query: inout ItemQuery, inspectedID: inout ScanItem.ID?,
                     enabled: Set<ModuleID> = ModuleRegistry.enabledIDs) {
        let target = Self.destination(for: item.category, enabled: enabled)
        selection = target
        query.scope = target
        query.searchText = ""
        query.tiers.insert(item.tier)
        inspectedID = item.id
        AccessibilityNotification.Announcement(
            loc("nav.revealed.a11y", "Showing \(item.uiDisplayName()) in the list")).post()
    }

    /// The module for a category, or the plain category list when that module isn't enabled.
    nonisolated static func destination(for category: ItemCategory, enabled: Set<ModuleID>) -> SidebarSelection {
        let module: ModuleID? = switch category {
        case .aiToolData: .aiTools
        case .worktree, .buildArtifact: .worktrees
        case .modelWeights, .docker: .modelsDocker
        case .largeFile: .largeOld
        case .duplicate: .duplicates
        case .application, .appLeftover: .uninstaller
        case .startupItem: .startupItems
        case .systemJunk: nil
        }
        if let module, enabled.contains(module) { return SidebarSelection(module: module) }
        return .category(category)
    }
}
