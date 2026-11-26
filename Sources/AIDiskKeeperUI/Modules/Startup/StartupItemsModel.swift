import AppKit
import DiskKeeperCore
import Foundation
import Observation

/// State of the Startup Items screen. Nothing here changes a launch item: removal goes through `CleanupCoordinator`,
/// and only for a user's own broken agents.
@MainActor @Observable
final class StartupItemsModel {
    enum Phase: Equatable { case idle, loading, ready, failed(String) }
    enum Filter: Equatable, CaseIterable { case all, user, system, broken }

    typealias Inventorying = @Sendable () async throws -> StartupInventory

    private(set) var phase: Phase = .idle
    private(set) var items: [StartupItem] = []
    private(set) var warnings: [ScanWarning] = []
    var filter: Filter = .all
    var sortOrder: [StartupItemComparator] = [StartupItemComparator(column: .item)]
    var inspectedID: String?
    let selection = SelectionModel()
    var finder: any FinderRevealing = SystemFinder()
    @ObservationIgnored var copyToPasteboard: (String) -> Void = {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString($0, forType: .string)
    }
    @ObservationIgnored var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }

    @ObservationIgnored private let inventory: Inventorying
    @ObservationIgnored private var scanItems: [String: ScanItem] = [:]

    init(inventory: @escaping Inventorying) { self.inventory = inventory }

    // MARK: Loading

    /// Runs the inventory off the main actor. Cancelling the calling task abandons the run.
    func refresh() async {
        if phase != .ready { phase = .loading }
        let inventory = inventory
        let task = Task.detached(priority: .userInitiated) { try await inventory() }
        do {
            let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            guard !Task.isCancelled else { return }
            adopt(result)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            phase = .failed(String(describing: error))
        }
    }

    private func adopt(_ result: StartupInventory) {
        items = result.items
        warnings = result.warnings
        scanItems = Dictionary(result.items.map { ($0.id, $0.makeScanItem()) }, uniquingKeysWith: { a, _ in a })
        selection.deselectAll()
        if let id = inspectedID, !result.items.contains(where: { $0.id == id }) { inspectedID = nil }
        phase = .ready
    }

    // MARK: Derived

    var userCount: Int { items.filter { $0.domain == .userAgent }.count }
    var systemCount: Int { items.filter { $0.domain != .userAgent }.count }
    var brokenCount: Int { items.filter { $0.programState == .missing }.count }
    var loadStateUnavailable: Bool { !warnings.isEmpty }

    func matches(_ item: StartupItem, _ f: Filter) -> Bool {
        switch f {
        case .all: true
        case .user: item.domain == .userAgent
        case .system: item.domain != .userAgent
        case .broken: item.programState == .missing
        }
    }

    var rows: [StartupItem] { items.filter { matches($0, filter) }.sorted(using: sortOrder) }
    var inspectedItem: StartupItem? { inspectedID.flatMap { id in items.first { $0.id == id } } }

    func scanItem(for item: StartupItem) -> ScanItem {
        scanItems[item.id] ?? item.makeScanItem()
    }

    /// The ticked rows. Only removable items can be ticked, and this re-checks.
    var selectedItems: [ScanItem] {
        selection.selectedItems(in: rows.filter(\.isRemovable).map(scanItem(for:)))
    }

    // MARK: Actions

    func review(using coordinator: CleanupCoordinator) {
        let chosen = selectedItems
        guard !chosen.isEmpty else { return }
        coordinator.review(chosen) { [weak self] trashed in self?.removeTrashed(trashed) }
    }

    /// After a cleanup: forget the trashed plists locally (no rescan) and clear the selection.
    func removeTrashed(_ trashed: Set<ScanItem.ID>) {
        guard !trashed.isEmpty else { selection.deselectAll(); return }
        let gone = Set(items.filter { trashed.contains(scanItem(for: $0).id) }.map(\.id))
        items.removeAll { gone.contains($0.id) }
        for id in gone { scanItems[id] = nil }
        selection.deselectAll()
        if let id = inspectedID, gone.contains(id) { inspectedID = nil }
    }

    func revealPlist(_ item: StartupItem) { finder.reveal(URL(fileURLWithPath: item.plistPath)) }

    func revealProgram(_ item: StartupItem) {
        guard item.programState == .present, let p = item.program else { return }
        finder.reveal(URL(fileURLWithPath: p))
    }

    func copyBrewCommand(_ item: StartupItem) {
        guard item.isHomebrewService, let label = item.label else { return }
        copyToPasteboard(StartupCopy.brewCommand(label))
    }

    func copyLabel(_ item: StartupItem) {
        guard let label = item.label else { return }
        copyToPasteboard(label)
    }

    func openLoginItemsSettings() { openURL(SystemSettingsLinks.loginItems) }
}

/// Sorts the table by one column and direction.
struct StartupItemComparator: SortComparator, Hashable {
    enum Column: Hashable, Sendable { case item, status }

    var column: Column
    var order: SortOrder = .forward

    func compare(_ l: StartupItem, _ r: StartupItem) -> ComparisonResult {
        let base: ComparisonResult = switch column {
        case .item: l.displayName.localizedStandardCompare(r.displayName)
        case .status: StartupCopy.status(l).localizedStandardCompare(StartupCopy.status(r))
        }
        let result: ComparisonResult = base == .orderedSame
            ? (l.plistPath < r.plistPath ? .orderedAscending : l.plistPath > r.plistPath ? .orderedDescending : .orderedSame)
            : base
        guard order == .reverse else { return result }
        return result == .orderedAscending ? .orderedDescending : result == .orderedDescending ? .orderedAscending : .orderedSame
    }
}
