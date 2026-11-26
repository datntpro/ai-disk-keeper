import DiskKeeperCore
import Foundation

/// Every user-visible string of the Startup Items screen.
enum StartupCopy {
    static var title: String { loc("startup.title", "Startup Items") }
    static var subtitle: String { loc("startup.subtitle", "What starts at login or runs in the background") }
    static var openLoginItems: String { loc("startup.openLoginItems", "Open Login Items settings") }
    static var cardUser: String { loc("startup.card.user", "Your launch agents") }
    static var cardSystem: String { loc("startup.card.system", "System-wide agents & daemons") }
    static var cardSystemNote: String { loc("startup.card.systemNote", "/Library — view only") }
    static var cardBroken: String { loc("startup.card.broken", "Broken (program missing)") }
    static var cardBrokenNote: String { loc("startup.card.brokenNote", "left behind by removed apps") }
    static var colItem: String { loc("startup.col.item", "Item") }
    static var colWhere: String { loc("startup.col.where", "Where") }
    static var colRuns: String { loc("startup.col.runs", "Runs") }
    static var colStatus: String { loc("startup.col.status", "Status") }
    static var footerNote: String {
        loc("startup.footer.note", "Only your own broken agents can be removed here. Everything else links to System Settings or the owning tool.")
    }
    static var review: String { loc("startup.action.review", "Review removal…") }
    static var refresh: String { loc("startup.action.refresh", "Refresh") }
    static var copyCommand: String { loc("startup.action.copyCommand", "Copy command") }
    static var copyLabel: String { loc("startup.action.copyLabel", "Copy label") }
    static var revealPlist: String { loc("startup.action.revealPlist", "Reveal file in Finder") }
    static var revealProgram: String { loc("startup.action.revealProgram", "Reveal program") }
    static var loading: String { loc("startup.loading", "Reading startup items…") }
    static var failedTitle: String { loc("startup.failed.title", "Couldn't read startup items") }
    static var emptyBroken: String { loc("startup.empty.broken", "No broken launch agents — nothing was left behind.") }
    static var emptyNone: String { loc("startup.empty.none", "No items in this list.") }
    static var emptyTitle: String { loc("startup.empty.title", "Nothing to show") }
    static var loadStateWarning: String {
        loc("startup.warning.loadState", "Couldn't read which items are loaded. Status shows as unknown.")
    }
    static var missingMark: String { loc("startup.program.missing", "— missing") }
    static var managed: String { loc("startup.program.managed", "Managed by an app") }
    static var unresolved: String { loc("startup.program.unresolved", "Not a plain file path") }
    static var inspectorEmpty: String { loc("startup.inspector.empty", "Select an item to see its details.") }
    static var explainSystem: String {
        loc("startup.explain.system", "Installed for all users. Change it in System Settings › Login Items, or with the app that installed it.")
    }
    static func explainBroken(_ program: String) -> String {
        loc("startup.explain.broken", "Starts \(program), which no longer exists. Removing this file only stops macOS trying to launch it.")
    }
    static var fieldFile: String { loc("startup.field.file", "File") }
    static var fieldProgram: String { loc("startup.field.program", "Program") }
    static var fieldArguments: String { loc("startup.field.arguments", "Arguments") }
    static var fieldSigner: String { loc("startup.field.signer", "Signed by") }
    static var fieldModified: String { loc("startup.field.modified", "Last modified") }

    static func domain(_ d: StartupItem.Domain) -> String {
        switch d {
        case .userAgent: loc("startup.domain.user", "User agent")
        case .systemAgent: loc("startup.domain.systemAgent", "System agent")
        case .systemDaemon: loc("startup.domain.daemon", "System daemon")
        }
    }

    static func countLabel(_ n: Int) -> String { Formatting.count(n) }

    // MARK: Schedules

    /// "4 h": the unit comes from the catalog so Vietnamese reads "4 giờ".
    static func shortDuration(_ seconds: Int) -> String {
        if seconds % 86_400 == 0 { return loc("startup.unit.day", "\(Formatting.count(seconds / 86_400)) d") }
        if seconds % 3_600 == 0 { return loc("startup.unit.hour", "\(Formatting.count(seconds / 3_600)) h") }
        if seconds % 60 == 0 { return loc("startup.unit.minute", "\(Formatting.count(seconds / 60)) min") }
        return loc("startup.unit.second", "\(Formatting.count(seconds)) s")
    }

    /// "4 hours", for VoiceOver.
    static func longDuration(_ seconds: Int) -> String {
        let f = DateComponentsFormatter()
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = L10n.locale
        f.calendar = calendar
        f.unitsStyle = .full
        f.allowedUnits = [.day, .hour, .minute, .second]
        f.maximumUnitCount = 2
        return f.string(from: TimeInterval(seconds)) ?? shortDuration(seconds)
    }

    static func schedule(_ s: StartupItem.Schedule, spoken: Bool = false) -> String {
        switch s {
        case .atLoad: loc("startup.runs.atLogin", "at login")
        case .keepAlive: loc("startup.runs.keepAlive", "keep alive")
        case .interval(let seconds): loc("startup.runs.every", "every \(spoken ? longDuration(seconds) : shortDuration(seconds))")
        case .calendar: loc("startup.runs.calendar", "on a schedule")
        case .onDemand: loc("startup.runs.onDemand", "on demand")
        }
    }

    /// "at login, every 4 h".
    static func runs(_ item: StartupItem, spoken: Bool = false) -> String {
        item.schedules.map { schedule($0, spoken: spoken) }.joined(separator: ", ")
    }

    // MARK: Status

    static func loadState(_ s: StartupItem.LoadState) -> String {
        switch s {
        case .running: loc("startup.status.running", "Running")
        case .loaded: loc("startup.status.loaded", "Loaded")
        case .notLoaded: loc("startup.status.notLoaded", "Not loaded")
        case .unknown: loc("startup.status.unknown", "Status unknown")
        }
    }

    static func signerName(_ source: AppSource?) -> String? {
        switch source {
        case .apple: "Apple"
        case .developerID(let team): team
        case .appStore(let team): team ?? "App Store"
        case .unsigned, .unknown, nil: nil
        }
    }

    static func signedBy(_ name: String) -> String { loc("startup.status.signedBy", "\(name) (signed)") }

    /// The `brew services` name of a Homebrew label (`homebrew.mxcl.postgresql@16` → `postgresql@16`).
    static func brewName(_ label: String) -> String { String(label.dropFirst("homebrew.mxcl.".count)) }
    static func brewCommand(_ label: String) -> String { "brew services stop \(brewName(label))" }
    static func brewHint(_ label: String) -> String {
        loc("startup.brew.hint", "Use brew services stop \(brewName(label))")
    }

    static var damaged: String { loc("startup.status.damaged", "Can't be read (damaged file)") }
    static var missingSafe: String { loc("startup.status.missing", "Program missing · Safe to remove") }
    static var viewOnly: String { loc("startup.status.viewOnly", "View only") }

    /// One line for the Status column.
    static func status(_ item: StartupItem) -> String {
        if item.label == nil { return damaged }
        if item.isRemovable { return missingSafe }
        var parts: [String] = []
        if item.isHomebrewService {
            if case .running = item.loadState { parts.append(loadState(item.loadState)) }
            parts.append(brewHint(item.label ?? ""))
            return parts.joined(separator: " · ")
        }
        if item.isBundleManaged { parts.append(managed) }
        parts.append(loadState(item.loadState))
        if let name = signerName(item.signer) { parts.append(signedBy(name)) }
        if item.programState == .missing { parts.append(loc("startup.status.programMissing", "Program missing")) }
        if !item.isRemovable, item.domain != .userAgent || item.programState == .missing { parts.append(viewOnly) }
        return parts.joined(separator: " · ")
    }

    static func rowA11y(_ item: StartupItem) -> String {
        loc("startup.a11y.row", "\(item.displayName), \(domain(item.domain)), \(runs(item, spoken: true)), \(status(item))")
    }
}
