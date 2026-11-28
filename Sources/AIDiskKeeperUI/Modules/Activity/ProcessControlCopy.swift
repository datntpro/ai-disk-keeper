import DiskKeeperCore
import Foundation

/// Every string of process control (prefix `proc.`).
enum ProcessControlCopy {
    // Actions
    static var background: String { loc("proc.action.background", "Run in background") }
    static var restorePriority: String { loc("proc.action.restore", "Restore priority") }
    static var pause: String { loc("proc.action.pause", "Pause…") }
    static var resume: String { loc("proc.action.resume", "Resume") }
    static var resumeAll: String { loc("proc.action.resumeAll", "Resume all") }
    static var actionsHelp: String { loc("proc.action.menu", "Process actions") }
    static var colActions: String { loc("proc.col.actions", "Actions") }

    // Chips
    static var chipBackground: String { loc("proc.chip.background", "Background") }
    static func chipPaused(_ remaining: String) -> String { loc("proc.chip.paused", "Paused · resumes in \(remaining)") }
    static func minutes(_ n: Int) -> String { loc("proc.minutes", "\(Formatting.count(n)) min") }
    static var lessThanMinute: String { loc("proc.lessThanMinute", "under a minute") }
    static var pausedSection: String { loc("proc.section.paused", "Paused by AI Disk Keeper") }
    static func pausedCount(_ n: Int) -> String { loc("proc.popover.paused", "\(Formatting.count(n)) paused") }

    // Sheet
    static func title(_ action: ProcessAction) -> String {
        switch action {
        case .background: loc("proc.sheet.title.background", "Run in background?")
        case .pause: loc("proc.sheet.title.pause", "Pause these processes?")
        case .restorePriority: loc("proc.sheet.title.restore", "Restore priority?")
        case .resume: loc("proc.sheet.title.resume", "Resume these processes?")
        }
    }
    static var includeChildren: String { loc("proc.sheet.includeChildren", "Include child processes") }
    static var keepChildren: String {
        loc("proc.sheet.keepChildren", "Keep new child processes in background while the app runs")
    }
    static var backgroundNote: String {
        loc("proc.sheet.backgroundNote", "The system gives these processes less CPU and disk time. They keep running, and the change ends when they exit or when you restore it.")
    }
    static func autoResume(_ minutes: Int) -> String {
        loc("proc.sheet.autoResume", "They resume automatically in \(Formatting.count(minutes)) min. You can change this in Settings.")
    }
    static var warnTimeout: String { loc("proc.sheet.warn.timeout", "A paused agent may time out its current request.") }
    static var warnGitLock: String {
        loc("proc.sheet.warn.gitLock", "A paused git command keeps its lock; other git commands in this repo will wait.")
    }
    static var warnNothingKilled: String { loc("proc.sheet.warn.nothingKilled", "Nothing is killed.") }
    static var noneAllowed: String { loc("proc.sheet.noneAllowed", "None of these processes can be changed.") }
    static var cancel: String { loc("proc.sheet.cancel", "Cancel") }
    static func confirm(_ action: ProcessAction) -> String {
        switch action {
        case .background: loc("proc.sheet.confirm.background", "Run in Background")
        case .pause: loc("proc.sheet.confirm.pause", "Pause")
        case .restorePriority: loc("proc.sheet.confirm.restore", "Restore")
        case .resume: loc("proc.sheet.confirm.resume", "Resume")
        }
    }
    static var colProcess: String { loc("proc.sheet.col.process", "Process") }
    static var colStatus: String { loc("proc.sheet.col.status", "Status") }
    static var okRow: String { loc("proc.sheet.ok", "Ready") }
    static func failed(_ code: Int32) -> String { loc("proc.result.failed", "Failed (error \(Int(code)))") }
    static var resultsTitle: String { loc("proc.result.title", "Some processes were not changed") }

    // Refusals
    static func refusal(_ r: ProcessRefusal) -> String {
        switch r {
        case .otherUser: loc("proc.refuse.otherUser", "Belongs to another user")
        case .systemProcess: loc("proc.refuse.system", "System process")
        case .ownProcessOrAncestor: loc("proc.refuse.own", "This app or the app that started it")
        case .guiAppPause: loc("proc.refuse.gui", "App with windows: can't be paused (you can still lower its priority)")
        case .launchd: loc("proc.refuse.launchd", "Core system process")
        case .identityChanged: loc("proc.refuse.changed", "The process changed since you selected it")
        case .vanished: loc("proc.refuse.vanished", "Already exited")
        case .denylisted(let name): loc("proc.refuse.denylisted", "\(name) is part of macOS and is never paused")
        case .unreadablePath: loc("proc.refuse.unreadable", "Can't verify what this process is")
        }
    }

    // Recovery
    static var recoveryTitle: String { loc("proc.recovery.title", "These processes are still paused") }
    static var recoveryMessage: String {
        loc("proc.recovery.message", "AI Disk Keeper paused them before it last closed. Resume them now, or leave them paused for a while longer.")
    }
    static var recoveryResume: String { loc("proc.recovery.resume", "Resume all") }
    static var recoveryLeave: String { loc("proc.recovery.leave", "Leave paused") }

    // Settings
    static var settingsSection: String { loc("proc.settings.section", "Pausing processes") }
    static func settingsAutoResume(_ minutes: Int) -> String {
        loc("proc.settings.autoResume", "Resume paused processes after \(Formatting.count(minutes)) min")
    }
    static var settingsNote: String {
        loc("proc.settings.note", "A paused process always resumes by itself. Everything is also resumed when AI Disk Keeper quits.")
    }

    // History
    static var historyFilterAll: String { loc("proc.history.all", "All") }
    static var historyFilterProcesses: String { loc("proc.history.processes", "Processes") }
    static var historyFilterLabel: String { loc("proc.history.filter", "Show") }
    static var historyRun: String { loc("proc.history.run", "Process control") }
    static func historyAction(_ raw: String) -> String {
        switch raw {
        case "background": background
        case "restorePriority": restorePriority
        case "pause": loc("proc.history.pause", "Pause")
        case "resume": resume
        default: raw
        }
    }
    static func historyResult(_ raw: String) -> String {
        if raw == "done" { return loc("proc.history.done", "Done") }
        if raw == "failed" { return loc("proc.history.failed", "Failed") }
        if raw.hasPrefix("refused") { return loc("proc.history.refused", "Refused") }
        return raw
    }
}
