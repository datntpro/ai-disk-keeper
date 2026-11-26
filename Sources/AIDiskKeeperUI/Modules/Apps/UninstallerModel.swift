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
    private(set) var running: Set<String> = []
    private(set) var selection = UninstallSelection()
    private(set) var orphanSelection: Set<ScanItem.ID> = []
    private(set) var lastGuidance: UninstallGuidance?
    var tab: Tab = .apps
    var search = ""
    var selectedAppID: InstalledApp.ID?

    @ObservationIgnored private let inventory: Inventorying
    @ObservationIgnored private let leftovers: Leftovers
    @ObservationIgnored private let runningApps: @MainActor () -> Set<String>
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored let home: String
    @ObservationIgnored private var task: Task<Void, Never>?

    init(inventory: @escaping Inventorying, leftovers: @escaping Leftovers,
         runningApps: @escaping @MainActor () -> Set<String>, home: String = NSHomeDirectory(),
         now: @escaping () -> Date = Date.init) {
        self.inventory = inventory
        self.leftovers = leftovers
        self.runningApps = runningApps
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
            running = runningApps()
            apps = inv.apps.sorted { l, r in
                let lv = l.viewOnlyReason != nil, rv = r.viewOnlyReason != nil
                if lv != rv { return !lv }
                if l.sizeAllocated != r.sizeAllocated { return l.sizeAllocated > r.sizeAllocated }
                return l.name.localizedStandardCompare(r.name) == .orderedAscending
            }
            partition(found?.items ?? [])
            if let id = selectedAppID, apps.contains(where: { $0.id == id }) {
                selection = UninstallSelection(app: apps.first { $0.id == id }!, group: group(forAppID: id))
            } else {
                selectedAppID = nil
                selection = UninstallSelection()
            }
            orphanSelection.formIntersection(orphans.map(\.id))
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

    /// Apps you could remove that haven't been opened for 90+ days (never-opened counts).
    var unusedCount: Int {
        let cutoff = now().addingTimeInterval(-Self.unusedDays * 86_400)
        return apps.filter { $0.viewOnlyReason == nil && ($0.lastUsed.map { $0 < cutoff } ?? true) }.count
    }

    var orphanBytes: Int64 { orphans.reduce(0) { $0 + $1.sizeAllocated } }

    func group(for app: InstalledApp) -> UninstallGroup { group(forAppID: app.id) }

    private func group(forAppID id: InstalledApp.ID) -> UninstallGroup {
        guard let app = apps.first(where: { $0.id == id }) else { return UninstallGroup() }
        let names = Self.foldedNames(app)
        return UninstallGroup(related: related["app:\(app.bundleID)"] ?? [],
                              shared: shared.filter { names.contains(UninstallLibrary.fold(($0.path as NSString).lastPathComponent)) })
    }

    /// Who else could own a shared entry (the installed apps whose name it carries).
    func owners(of item: ScanItem) -> [InstalledApp] {
        let name = UninstallLibrary.fold((item.path as NSString).lastPathComponent)
        return apps.filter { Self.foldedNames($0).contains(name) && $0.source != .apple }
    }

    private static func foldedNames(_ app: InstalledApp) -> Set<String> {
        Set([app.name, app.bundleName].compactMap { $0 }.map(UninstallLibrary.fold))
    }

    func canUninstall(_ app: InstalledApp) -> UninstallAvailability {
        if let reason = app.viewOnlyReason { return .viewOnly(reason) }
        return running.contains(app.bundleID) ? .running : .available
    }

    func isRunning(_ app: InstalledApp) -> Bool { running.contains(app.bundleID) }

    func guidance(for app: InstalledApp) -> UninstallGuidance? {
        UninstallGuidance.resolve(app: app, availability: canUninstall(app), last: lastGuidance)
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

    func refreshRunning() { running = runningApps() }

    func select(_ app: InstalledApp) {
        selectedAppID = app.id
        selection = UninstallSelection(app: app, group: group(for: app))
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
            if let id = selectedAppID, gone.contains(id) { selectedAppID = nil; selection = UninstallSelection() }
        }
    }
}
