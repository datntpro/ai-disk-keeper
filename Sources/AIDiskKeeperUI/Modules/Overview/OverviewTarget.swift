import DiskKeeperCore
import SwiftUI

/// Where each Care Scan module lives in the app.
enum OverviewTarget {
    /// nil for System junk, which has no screen of its own (it opens its category list).
    static func moduleID(for module: CareModule) -> ModuleID? {
        switch module {
        case .aiTools: .aiTools
        case .worktrees: .worktrees
        case .modelsDocker: .modelsDocker
        case .systemJunk: nil
        case .largeOld: .largeOld
        case .duplicates: .duplicates
        case .apps: .uninstaller
        case .startup: .startupItems
        }
    }

    static func selection(for module: CareModule) -> SidebarSelection {
        moduleID(for: module).map { SidebarSelection(module: $0) } ?? .category(.systemJunk)
    }

    static func title(for module: CareModule) -> String {
        moduleID(for: module).map { ModuleRegistry.descriptor(for: $0).title } ?? ItemCategory.systemJunk.uiName
    }

    static func symbol(for module: CareModule) -> String {
        moduleID(for: module).map { ModuleRegistry.descriptor(for: $0).symbol } ?? "trash.slash"
    }

    static func chipTitle(_ module: CareModule) -> String {
        switch module {
        case .aiTools: loc("care.chip.aiTools", "AI tools")
        case .worktrees: loc("care.chip.worktrees", "Worktrees")
        case .modelsDocker: loc("care.chip.modelsDocker", "Models & Docker")
        case .systemJunk: loc("care.chip.systemJunk", "System junk")
        case .largeOld: loc("care.chip.largeOld", "Large & old")
        case .duplicates: loc("care.chip.duplicates", "Duplicates")
        case .apps: loc("care.chip.apps", "Apps")
        case .startup: loc("care.chip.startup", "Startup")
        }
    }
}
