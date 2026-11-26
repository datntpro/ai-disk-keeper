import DiskKeeperCore
import Foundation
import Observation

/// State of the Uninstaller. Nothing here touches a file: uninstalling hands a reviewed plan to the cleanup
/// engine through `CleanupCoordinator`, which re-checks everything (running, Apple, symlink, owner) itself.
@MainActor @Observable
final class UninstallerModel {
    enum Phase: Equatable { case idle, loading, ready, failed(String) }
    enum Tab: Hashable { case apps, orphans }

    typealias Inventorying = @Sendable () async throws -> AppInventory
    /// One leftover scan (`AppLeftoverScanner` through `ScanEngine`) for the given inventory.
    typealias Leftovers = @Sendable (AppInventory) async throws -> ScanResult

    static let unusedDays = 90.0

    private(set) var phase: Phase = .idle
    /// Size descending; apps that can't be uninstalled last.
    private(set) var apps: [InstalledApp] = []
    /// `app:<bundleID>` → exact and single-owner name matches.
    private(set) var related: [String: [ScanItem]] = [:]
    /// Name-level entries several apps could own.
    private(set) var shared: [ScanItem] = []
    private(set) var orphans: [ScanItem] = []
    /// The leftover scan failed: "nothing found" would be a guess, so the screen says it couldn't read them.
    private(set) var leftoversFailed = false
    /// Apps with anything running from them: the app itself, a helper app, or a background process inside the
    /// bundle. The same three checks the cleanup engine makes, so the screen and the engine agree.
    private(set) var running: Set<InstalledApp.ID> = []
    /// The process list couldn't be read: every app that could be uninstalled counts as running.
    var runningUnknown = false
    /// What is running from the selected app (nil when nothing is, or it couldn't be read).
    var detail: AppRunState?
    var detailUnknown = false
    /// One quit flow per app id (see `AppQuitFlow.swift`).
    var quitFlows: [InstalledApp.ID: QuitFlowState] = [:]
    var forceConfirmation: ForceConfirmation?
    private(set) var selection = UninstallSelection()
    private(set) var orphanSelection: Set<ScanItem.ID> = []
    private(set) var lastGuidance: UninstallGuidance?
    var tab: Tab = .apps
    var search = ""
    var selectedAppID: InstalledApp.ID?

    @ObservationIgnored private let inventory: Inventorying
    @ObservationIgnored private let leftovers: Leftovers
    @ObservationIgnored let processes: AppProcessControlling
    @ObservationIgnored let audit: QuitAudit
    @ObservationIgnored let identity: SelfIdentity
    @ObservationIgnored let sleep: Sleeper
    @ObservationIgnored let now: () -> Date
    @ObservationIgnored var quitTasks: [InstalledApp.ID: Task<Void, Never>] = [:]
    @ObservationIgnored let home: String
    @ObservationIgnored private var task: Task<Void, Never>?

    init(inventory: @escaping Inventorying, leftovers: @escaping Leftovers,
         processes: AppProcessControlling, audit: @escaping QuitAudit = { _ in },
         identity: SelfIdentity = .live, sleep: @escaping Sleeper = { try await Task.sleep(for: $0) },
         home: String = NSHomeDirectory(), now: @escaping () -> Date = Date.init) {
        self.inventory = inventory
        self.leftovers = leftovers
        self.processes = processes
        self.audit = audit
        self.identity = identity
        self.sleep = sleep
        self.home = home
        self.now = now
    }

    // MARK: Loading

    /// Reads the apps, then their leftovers. The old data stays on screen while it reloads.
    func load() {
        guard task == nil else { return }
        if phase != .ready { phase = .loading }
        let inventory = inventory, leftovers = leftovers
        task = Task { [weak self] in
            let result: Result<(AppInventory, ScanResult?), Error>
            do {
                let inv = try await inventory()
                // Leftovers are a bonus: without them the app list is still right.
                let found = try? await leftovers(inv)
                result = .success((inv, found))
            } catch { result = .failure(error) }
            self?.finishLoad(result)
        }
    }

    /// Test hook: resolves when no load is running.
    func settle() async { while let current = task { await current.value } }

    private func finishLoad(_ result: Result<(AppInventory, ScanResult?), Error>) {
        task = nil
        switch result {
        case .success(let (inv, found)):
            apps = inv.apps.sorted { l, r in
                let lv = l.viewOnlyReason != nil, rv = r.viewOnlyReason != nil
                if lv != rv { return !lv }
                if l.sizeAllocated != r.sizeAllocated { return l.sizeAllocated > r.sizeAllocated }
                return l.name.localizedStandardCompare(r.name) == .orderedAscending
            }
            leftoversFailed = found == nil
            partition(found?.items ?? [])
            if let id = selectedAppID, apps.contains(where: { $0.id == id }) {
                selection = UninstallSelection(app: apps.first { $0.id == id }!, group: group(forAppID: id))
            } else {
                selectedAppID = nil
                selection = UninstallSelection()
            }
            orphanSelection.formIntersection(orphans.map(\.id))
            let ids = Set(apps.map(\.id))
            for id in quitFlows.keys where !ids.contains(id) { quitTasks[id]?.cancel(); quitTasks[id] = nil; quitFlows[id] = nil }
            if let c = forceConfirmation, !ids.contains(c.appID) { forceConfirmation = nil }
            refreshRunning()
            phase = .ready
        case .failure(let error):
            if error is CancellationError { phase = apps.isEmpty ? .idle : .ready } else { phase = .failed(error.localizedDescription) }
        }
    }

    private func partition(_ items: [ScanItem]) {
        var related: [String: [ScanItem]] = [:]
        var shared: [ScanItem] = [], orphans: [ScanItem] = []
        for item in items {
            switch item.ruleID {
            case "apps.leftover.exact": if let g = item.groupID { related[g, default: []].append(item) }
            case "apps.leftover.name":
                if let g = item.groupID { related[g, default: []].append(item) } else { shared.append(item) }
            case "apps.leftover.orphan": orphans.append(item)
            default: continue
            }
        }
        let bySize: (ScanItem, ScanItem) -> Bool = { $0.sizeAllocated > $1.sizeAllocated }
        self.related = related.mapValues { $0.sorted(by: bySize) }
        self.shared = shared.sorted(by: bySize)
        self.orphans = orphans.sorted(by: bySize)
    }

    // MARK: Derived

    var selectedApp: InstalledApp? { selectedAppID.flatMap { id in apps.first { $0.id == id } } }

    var filteredApps: [InstalledApp] {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return apps }
        return apps.filter { $0.name.localizedCaseInsensitiveContains(q) || $0.bundleID.localizedCaseInsensitiveContains(q) }
    }

    /// Apps you could remove that haven't been opened for 90+ days (no usage record doesn't count: Spotlight may be off).
    var unusedCount: Int {
        let cutoff = now().addingTimeInterval(-Self.unusedDays * 86_400)
        return apps.filter { $0.viewOnlyReason == nil && ($0.lastUsed.map { $0 < cutoff } ?? false) }.count
    }

    var orphanBytes: Int64 { orphans.reduce(0) { $0 + $1.sizeAllocated } }

    func group(for app: InstalledApp) -> UninstallGroup { group(forAppID: app.id) }

    private func group(forAppID id: InstalledApp.ID) -> UninstallGroup {
        guard let app = apps.first(where: { $0.id == id }) else { return UninstallGroup() }
        return UninstallGroup(related: related["app:\(app.bundleID)"] ?? [], shared: shared.filter { Self.owns(app, $0) })
    }

    /// Who else could own a shared entry (the installed apps whose name it carries).
    func owners(of item: ScanItem) -> [InstalledApp] {
        apps.filter { $0.source != .apple && Self.owns($0, item) }
    }

    /// A shared entry may belong to an app by folder name, or (Group Containers) by the team prefix `<TEAMID>.*`.
    private static func owns(_ app: InstalledApp, _ item: ScanItem) -> Bool {
        let last = (item.path as NSString).lastPathComponent
        if foldedNames(app).contains(UninstallLibrary.fold(last)) { return true }
        guard UninstallLibrary.location(of: item.path) == "Group Containers", let team = app.source.teamID,
              let prefix = last.split(separator: ".", maxSplits: 1).first else { return false }
        return UninstallLibrary.fold(String(prefix)) == UninstallLibrary.fold(team)
    }

    /// Owner names for a shared row, each once ("ADKQA Twin, ADKQA Twin" → "ADKQA Twin").
    func ownerNames(of item: ScanItem) -> String {
        Array(Set(owners(of: item).map(\.name))).sorted { $0.localizedStandardCompare($1) == .orderedAscending }.joined(separator: ", ")
    }

    private static func foldedNames(_ app: InstalledApp) -> Set<String> {
        Set([app.name, app.bundleName].compactMap { $0 }.map(UninstallLibrary.fold))
    }

    func canUninstall(_ app: InstalledApp) -> UninstallAvailability {
        if let reason = app.viewOnlyReason { return .viewOnly(reason) }
        return running.contains(app.id) ? .running : .available
    }

    func isRunning(_ app: InstalledApp) -> Bool { running.contains(app.id) }

    func guidance(for app: InstalledApp) -> UninstallGuidance? {
        var info: UninstallGuidance.RunInfo?
        if canUninstall(app) == .running {
            let mine = selectedAppID == app.id
            let state = mine ? detail : nil
            info = UninstallGuidance.RunInfo(
                unknown: runningUnknown || (mine && detailUnknown), selfApp: appRefusal(app) == .selfApp,
                quit: quitFlows[app.id], canQuit: canQuit(app), background: state.map(backgroundNames) ?? [],
                otherUser: state.map { s in s.instances.contains { $0.kind != .background && instanceRefusal($0) != nil } } ?? false)
        }
        return UninstallGuidance.resolve(app: app, availability: canUninstall(app), last: lastGuidance, run: info,
                                         quit: quitFlows[app.id])
    }

    /// The ticked leftovers of the selected app (never another app's).
    var tickedRelated: [ScanItem] {
        guard let app = selectedApp, selection.appID == app.id else { return [] }
        return selection.items(in: group(for: app))
    }

    var tickedBytes: Int64 { (selectedApp?.sizeAllocated ?? 0) + tickedRelated.reduce(0) { $0 + $1.sizeAllocated } }

    var resetItems: [ScanItem] { selectedApp.map { group(for: $0).resetItems } ?? [] }

    var canReset: Bool {
        guard let app = selectedApp else { return false }
        return !resetItems.isEmpty && !isRunning(app)
    }

    // MARK: Actions

    /// Re-reads what is running. No inventory or leftover scan: only the process lists.
    func refreshRunning() {
        if let ids = processes.runningAppIDs(for: apps) {
            running = ids
            runningUnknown = false
        } else {
            running = Set(apps.filter { $0.viewOnlyReason == nil }.map(\.id))
            runningUnknown = true
        }
        refreshDetail()
        resumeStuckFlows()
    }

    private func refreshDetail() {
        detail = nil
        detailUnknown = false
        guard let app = selectedApp, running.contains(app.id), !runningUnknown else { return }
        if let state = processes.runState(for: app) { detail = state } else { detailUnknown = true }
    }

    func select(_ app: InstalledApp) {
        selectedAppID = app.id
        selection = UninstallSelection(app: app, group: group(for: app))
        for (id, state) in quitFlows where state == .done { quitFlows[id] = nil }
        refreshDetail()
    }

    func toggle(_ item: ScanItem) {
        guard let app = selectedApp else { return }
        selection.toggle(item, in: group(for: app))
    }

    func toggleOrphan(_ item: ScanItem) {
        guard item.isSelectable, orphans.contains(where: { $0.id == item.id }) else { return }
        if orphanSelection.remove(item.id) == nil { orphanSelection.insert(item.id) }
    }

    var tickedOrphans: [ScanItem] { orphans.filter { orphanSelection.contains($0.id) && $0.isSelectable } }

    /// Groups the orphans by the bundle id they are named after, biggest first.
    var orphanGroups: [(key: String, items: [ScanItem])] {
        let grouped = Dictionary(grouping: orphans, by: UninstallLibrary.orphanKey)
        return grouped.map { (key: $0.key, items: $0.value) }
            .sorted { l, r in
                let (lb, rb) = (l.items.reduce(0) { $0 + $1.sizeAllocated }, r.items.reduce(0) { $0 + $1.sizeAllocated })
                return lb != rb ? lb > rb : l.key < r.key
            }
    }

    /// Opens the cleanup sheet for the bundle plus the ticked leftovers. A no-op for anything that can't be
    /// uninstalled; the engine refuses those too.
    func uninstall(using coordinator: CleanupCoordinator) {
        guard let app = selectedApp, canUninstall(app) == .available else { return }
        review([app.makeScanItem()] + tickedRelated, app: app, using: coordinator)
    }

    /// Caches and saved state only; the app stays.
    func resetApp(using coordinator: CleanupCoordinator) {
        guard let app = selectedApp, canReset else { return }
        review(resetItems, app: app, using: coordinator)
    }

    func reviewOrphans(using coordinator: CleanupCoordinator) {
        let chosen = tickedOrphans
        guard !chosen.isEmpty else { return }
        coordinator.review(chosen) { [weak self] trashed in self?.removeTrashed(trashed) }
    }

    private func review(_ items: [ScanItem], app: InstalledApp, using coordinator: CleanupCoordinator) {
        guard !items.isEmpty else { return }
        lastGuidance = nil
        coordinator.review(items) { [weak self, weak coordinator] trashed in
            guard let self else { return }
            if let report = coordinator?.lastReport { self.lastGuidance = UninstallGuidance.from(report: report, bundleID: app.bundleID) }
            self.removeTrashed(trashed)
        }
    }

    /// After a cleanup: forget what was trashed locally. If the bundle went, so does the app.
    func removeTrashed(_ trashed: Set<ScanItem.ID>) {
        guard !trashed.isEmpty else { return }
        for key in related.keys { related[key]?.removeAll { trashed.contains($0.id) } }
        shared.removeAll { trashed.contains($0.id) }
        orphans.removeAll { trashed.contains($0.id) }
        orphanSelection.subtract(trashed)
        selection.remove(trashed)
        let gone = apps.filter { trashed.contains($0.makeScanItem().id) }.map(\.id)
        if !gone.isEmpty {
            apps.removeAll { gone.contains($0.id) }
            for id in gone { quitTasks[id]?.cancel(); quitTasks[id] = nil; quitFlows[id] = nil }
            if let id = selectedAppID, gone.contains(id) { selectedAppID = nil; selection = UninstallSelection() }
        }
    }
}
