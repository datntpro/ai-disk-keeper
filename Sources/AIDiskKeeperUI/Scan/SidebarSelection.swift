import DiskKeeperCore

public enum SidebarSelection: Hashable, Sendable {
    case overview
    case tool(ToolID)
    case category(ItemCategory)
    case warnings
    case module(ModuleID)

    /// The row selection for a module. Overview keeps its original `.overview` case.
    public init(module: ModuleID) { self = module == .overview ? .overview : .module(module) }

    /// The module that draws the detail pane, if the selection is a module (or Overview).
    public var moduleID: ModuleID? {
        switch self {
        case .overview: .overview
        case .module(let id): id
        case .tool, .category, .warnings: nil
        }
    }
}
