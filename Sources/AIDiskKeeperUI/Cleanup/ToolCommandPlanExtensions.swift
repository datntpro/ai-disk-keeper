import DiskKeeperCore
import Foundation

extension CleanupPlanEntry {
    var isToolCommand: Bool {
        if case .toolCommand = item.cleanupMethod { return true }
        return false
    }

    /// The command as the dry run showed it (blocked rows fall back to what the item declares).
    var commandLine: String? {
        if let toolCommand { return ToolCommandDisplay.line(toolCommand) }
        if case .toolCommand(let command, let args) = item.cleanupMethod { return ToolCommandDisplay.line(command: command, arguments: args) }
        return nil
    }

    var commandHelp: String? { toolCommand.map(ToolCommandDisplay.fullLine) }
}

extension CleanupPlan {
    var hasExecutableToolCommands: Bool { executableEntries.contains(where: \.isToolCommand) }
}
