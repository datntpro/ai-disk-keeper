import DiskKeeperCore
import Foundation

/// Every string of the Disk Activity screen and the popover's disk-activity list (prefix `hostio.`).
enum DiskActivityCopy {
    static var title: String { loc("hostio.module.title", "Disk activity") }
    static var popoverTitle: String { loc("hostio.popover.title", "Disk activity") }
    static var colWrites: String { loc("hostio.col.writes", "Writes/s") }
    static var colReads: String { loc("hostio.col.reads", "Reads/s") }
    static var colWritten: String { loc("hostio.col.written", "Written since start") }
    static var colProcesses: String { loc("hostio.col.processes", "Processes") }
    static var colAgent: String { loc("hostio.col.agent", "Agent") }
    static var colAgents: String { loc("hostio.col.agents", "Agents") }
    static var colWorktree: String { loc("hostio.col.worktree", "Worktree") }
    static var colProcess: String { loc("hostio.col.process", "Process") }
    static var byWorktree: String { loc("hostio.section.byWorktree", "By worktree") }
    static var byAgent: String { loc("hostio.section.byAgent", "By agent") }
    static var topProcesses: String { loc("hostio.section.topProcesses", "Top processes") }
    static var busy: String { loc("hostio.busy", "Disk busy (approx.)") }
    static var diskWrites: String { loc("hostio.diskWrites", "Disk writes") }
    static var diskReads: String { loc("hostio.diskReads", "Disk reads") }
    static var other: String { loc("hostio.otherProcesses", "Other processes (short-lived or other users)") }
    static var spotlightNote: String {
        loc("hostio.spotlightNote", "Exclude build folders from Spotlight in System Settings › Siri & Spotlight.")
    }
    static var emptyTitle: String { loc("hostio.empty.title", "Collecting samples") }
    static var emptyMessage: String { loc("hostio.empty.message", "Rates appear after the second sample, a few seconds from now.") }
    static var noAttribution: String { loc("hostio.noWorktree", "Not in a git folder") }
    static var unavailable: String { loc("hostio.unavailable", "Disk activity isn't available on this Mac.") }
    static func load(_ one: String, _ cpus: Int) -> String { loc("hostio.load", "Load \(one) on \(Formatting.count(cpus)) cores") }

    static func kindName(_ kind: AgentKind) -> String {
        switch kind {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .gemini: "Gemini CLI"
        case .aider: "Aider"
        case .cursor: "Cursor"
        case .orca: "Orca"
        case .node: "Node"
        case .bun: "Bun"
        case .python: "Python"
        case .go: "Go"
        case .swift: "Swift"
        case .cargo: "Cargo"
        case .git: "Git"
        case .xcodebuild: "Xcode"
        case .docker: "Docker"
        case .vm: loc("hostio.kind.vm", "Virtual machine")
        case .spotlight: "Spotlight"
        case .defender: "Microsoft Defender"
        case .other: loc("hostio.kind.other", "Other")
        }
    }
}
