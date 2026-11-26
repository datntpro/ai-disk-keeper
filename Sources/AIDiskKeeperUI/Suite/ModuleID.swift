/// Every module the suite sidebar can show, in the fixed registry order.
public enum ModuleID: String, CaseIterable, Sendable, Hashable {
    case overview, careScan, diskMap, largeOld, duplicates, storage
    case aiTools, worktrees, modelsDocker, uninstaller, startupItems, history
}
