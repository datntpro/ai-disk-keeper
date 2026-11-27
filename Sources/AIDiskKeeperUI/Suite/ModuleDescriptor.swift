import DiskKeeperCore

/// Static facts about a module. Titles are resolved when read, so a language switch shows up at once.
public struct ModuleDescriptor: Sendable, Equatable {
    public let id: ModuleID
    public let section: ModuleSection
    public let order: Int
    public let symbol: String
    /// A module's PR flips this to `true`; until then it is hidden in release builds.
    public let isEnabled: Bool
    /// Item categories listed by the shared item table. `nil` for screen modules that draw their own content.
    public let listCategories: Set<ItemCategory>?
    /// When set, the module lists only items whose rule id starts with one of these (still within `listCategories`).
    public let listRulePrefixes: [String]?

    public init(id: ModuleID, section: ModuleSection, order: Int, symbol: String, isEnabled: Bool,
                listCategories: Set<ItemCategory>? = nil, listRulePrefixes: [String]? = nil) {
        self.id = id
        self.section = section
        self.order = order
        self.symbol = symbol
        self.isEnabled = isEnabled
        self.listCategories = listCategories
        self.listRulePrefixes = listRulePrefixes
    }

    public var title: String {
        switch id {
        case .overview: loc("sidebar.overview", "Overview")
        case .careScan: loc("module.careScan", "Care Scan")
        case .diskMap: loc("module.diskMap", "Disk Map")
        case .largeOld: loc("module.largeOld", "Large & Old")
        case .duplicates: loc("module.duplicates", "Duplicates")
        case .storage: loc("module.storage", "Storage")
        case .aiTools: loc("module.aiTools", "AI Tools")
        case .worktrees: loc("module.worktrees", "Worktrees")
        case .modelsDocker: loc("module.modelsDocker", "Models & Docker")
        case .buildCaches: loc("caches.module.title", "Build caches")
        case .uninstaller: loc("module.uninstaller", "Uninstaller")
        case .startupItems: loc("module.startupItems", "Startup Items")
        case .diskActivity: loc("hostio.module.title", "Disk activity")
        case .history: loc("module.history", "Cleanup History")
        }
    }
}
