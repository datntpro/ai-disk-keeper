import DiskKeeperCore

public enum SidebarSelection: Hashable, Sendable {
    case overview
    case tool(ToolID)
    case category(ItemCategory)
    case warnings
}
