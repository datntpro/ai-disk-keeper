import DiskKeeperCore
import Foundation
import Observation

/// Remembers, per Mac, that the user accepted the GitHub CLI disclosure. Injected so tests never touch real defaults.
struct GitHubConsentStore: Sendable {
    var read: @Sendable () -> Bool
    var write: @Sendable () -> Void

    static func defaults(_ defaults: UserDefaults = .standard, key: String = "worktrees.githubConsent") -> GitHubConsentStore {
        nonisolated(unsafe) let d = defaults
        return GitHubConsentStore(read: { d.bool(forKey: key) }, write: { d.set(true, forKey: key) })
    }
    static func memory(_ initial: Bool = false) -> GitHubConsentStore {
        final class Box: @unchecked Sendable { var value: Bool; init(_ v: Bool) { value = v } }
        let box = Box(initial)
        return GitHubConsentStore(read: { box.value }, write: { box.value = true })
    }
}

/// The opt-in for `gh pr list`: turning it on the first time shows a consent sheet; later toggles do not.
@MainActor @Observable
final class GitHubConsentModel {
    var isSheetShown = false
    @ObservationIgnored private let current: () -> Bool
    @ObservationIgnored private let store: GitHubConsentStore
    @ObservationIgnored private let apply: (Bool) -> Void

    /// `isOn` reads the live setting (an observable model), so views track it.
    init(isOn: @escaping () -> Bool, store: GitHubConsentStore, apply: @escaping (Bool) -> Void) {
        self.current = isOn
        self.store = store
        self.apply = apply
    }

    var isOn: Bool { current() }
    /// The user has accepted the disclosure on this Mac. A setting copied in from elsewhere does not count.
    var hasConsented: Bool { store.read() }

    func request(_ on: Bool) {
        if !on { set(false); return }
        if store.read() { set(true) } else { isSheetShown = true }
    }

    func confirm() {
        store.write()
        isSheetShown = false
        set(true)
    }

    func cancel() { isSheetShown = false }

    private func set(_ on: Bool) { apply(on) }
}

enum WorktreeFilter: String, CaseIterable, Identifiable {
    case all, safe, inUse, changes
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: WorktreeCopy.filterAll
        case .safe: WorktreeCopy.filterSafe
        case .inUse: WorktreeCopy.filterInUse
        case .changes: WorktreeCopy.filterChanges
        }
    }

    func includes(_ row: WorktreeRow) -> Bool {
        switch self {
        case .all: true
        case .safe: row.verdict.eligible
        case .inUse: !(row.facts.processes ?? []).isEmpty || row.facts.containsOwnCWD
        case .changes: row.facts.git?.workingTree.map { !$0.isClean } ?? false
        }
    }
}

@MainActor @Observable
final class WorktreeManagerModel {
    enum Phase: Equatable { case idle, loading, ready }

    private(set) var phase: Phase = .idle
    private(set) var result: InventoryResult?
    var filter: WorktreeFilter = .all
    var selection: WorktreeRow.ID?
    let consent: GitHubConsentModel

    @ObservationIgnored private let makeInventory: @Sendable (AppSettings) -> WorktreeInventory?
    @ObservationIgnored private let currentSettings: () -> AppSettings
    @ObservationIgnored private var inventoryTask: Task<Void, Never>?

    init(settings: @escaping () -> AppSettings, consent: GitHubConsentModel,
         makeInventory: @escaping @Sendable (AppSettings) -> WorktreeInventory?) {
        self.consent = consent
        self.currentSettings = settings
        self.makeInventory = makeInventory
    }

    var rows: [WorktreeRow] { result?.rows ?? [] }
    var visibleRows: [WorktreeRow] { rows.filter { filter.includes($0) } }
    var selectedRow: WorktreeRow? { rows.first { $0.id == selection } }
    /// H4 turns this on; until then the toolbar button is a disabled placeholder.
    var canSelectSafe: Bool { false }
    var safeCount: Int { rows.filter { $0.verdict.eligible }.count }

    func refresh() {
        guard phase != .loading else { return }
        phase = .loading
        var settings = currentSettings()
        if settings.useGitHubCLIForPRs && !consent.hasConsented { settings.useGitHubCLIForPRs = false }
        let make = makeInventory
        inventoryTask = Task { [weak self] in
            let value: InventoryResult
            if let inventory = make(settings) {
                value = await inventory.refresh(settings: settings)
            } else {
                value = InventoryResult(warnings: [.orcaUnavailable("git not found")])
            }
            guard let self, !Task.isCancelled else { return }
            self.result = value
            if let s = self.selection, !value.rows.contains(where: { $0.id == s }) { self.selection = nil }
            self.phase = .ready
        }
    }

    /// Test seam: shows a finished inventory without running one.
    func show(_ value: InventoryResult) {
        result = value
        phase = .ready
    }

    func cancel() {
        inventoryTask?.cancel()
        if phase == .loading { phase = result == nil ? .idle : .ready }
    }

    func refreshIfNeeded() { if phase == .idle { refresh() } }

    /// Total size of every candidate, for the By-project header.
    var totalBytes: Int64 { rows.compactMap(\.facts.allocatedBytes).reduce(0, +) }
}

enum WorktreeInventoryFactory {
    /// The live inventory: real git, Orca CLI, process table. `nil` when git is not installed.
    static func live(environment env: PathEnvironment, github: GHCLIPRStatusSource) -> @Sendable (AppSettings) -> WorktreeInventory? {
        { settings in
            guard let gitURL = GitInspector.locateGit() else { return nil }
            let git = GitInspector(configuration: .init(homeDirectory: env.home, gitExecutable: gitURL))
            let loaded = RuleLoader(
                environment: env, bundledRulesDirectory: CoreResources.rulesDirectoryURL, userRulesDirectory: settings.userRulesEnabled ? UserRulesDirectory.defaultURL(environment: env) : nil,
                guardFactory: ScanGuard.loaderFactory(environment: env)).load()
            let guardian = try? ScanGuard(environment: env, protectPatterns: loaded.protectPatterns).protectedPaths
            let scope = settings.scanScope(environment: env)
            var ownCWDs = [FileManager.default.currentDirectoryPath]
            ownCWDs.append(Bundle.main.bundlePath)
            return WorktreeInventory(dependencies: .init(
                git: git, orca: OrcaWorktreeSource(home: env.home), prSource: github, processes: LibprocProcessTable(),
                protectedPaths: guardian, home: env.home, projectRoots: scope.projectRoots, ownCWDs: ownCWDs))
        }
    }
}
