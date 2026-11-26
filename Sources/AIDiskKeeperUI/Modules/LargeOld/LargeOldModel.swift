import DiskKeeperCore
import Foundation
import Observation

/// Opens a file in Finder. A seam so tests never touch the real Finder.
@MainActor
protocol FinderRevealing {
    func reveal(_ url: URL)
}

struct SystemFinder: FinderRevealing {
    func reveal(_ url: URL) { FinderReveal.reveal(url) }
}

/// State of the Large & Old screen: the report from the shared disk index, the filters, the selection.
/// Nothing here deletes: cleanup goes through `CleanupCoordinator`.
@MainActor @Observable
final class LargeOldModel {
    enum Phase: Equatable { case needsIndex, analysing, ready, failed(String) }

    typealias Scanning = @Sendable (DiskTree) async throws -> LargeFileReport

    private(set) var phase: Phase = .needsIndex
    private(set) var report: LargeFileReport?
    var filters = LargeOldFilters() { didSet { recompute() } }
    var sortOrder: [LargeFileComparator] = [LargeFileComparator(column: .size, order: .reverse)] { didSet { recompute() } }
    private(set) var rows: [LargeFile] = []
    private(set) var kindTotals: [LargeFileKind: (bytes: Int64, count: Int)] = [:]
    let selection = SelectionModel()
    var inspectedPath: String?
    var quickLookURL: URL?
    var finder: any FinderRevealing = SystemFinder()

    let index: DiskIndexModel
    @ObservationIgnored private let scanner: Scanning
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var analysedGeneration: Int?
    @ObservationIgnored private var items: [String: ScanItem] = [:]

    init(index: DiskIndexModel, scanner: @escaping Scanning, now: @escaping () -> Date = Date.init) {
        self.index = index
        self.scanner = scanner
        self.now = now
    }

    var currentTime: Date { now() }

    // MARK: Analysis

    /// Re-analyses when the index has a tree this model hasn't seen. Cancelling the calling task (the view's
    /// `.task(id:)` does it on a new generation) abandons the run; its late result is dropped.
    func refresh() async {
        guard let tree = index.tree else {
            if report == nil { phase = .needsIndex }
            return
        }
        let generation = index.generation
        if analysedGeneration == generation, report != nil { return }
        phase = .analysing
        let scanner = scanner
        let task = Task.detached(priority: .userInitiated) { try await scanner(tree) }
        do {
            let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            guard !Task.isCancelled, index.generation == generation else { return }
            adopt(result, generation: generation)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, index.generation == generation else { return }
            phase = .failed(String(describing: error))
        }
    }

    private func adopt(_ result: LargeFileReport, generation: Int) {
        report = result
        analysedGeneration = generation
        items = Dictionary(result.files.map { ($0.path, LargeFileScanner.makeItem($0)) }, uniquingKeysWith: { a, _ in a })
        selection.deselectAll()
        inspectedPath = nil
        quickLookURL = nil
        phase = .ready
        recompute()
    }

    private func recompute() {
        guard let files = report?.files else { rows = []; kindTotals = [:]; return }
        let at = now()
        let base = filters.kindFree(files, now: at)
        var totals: [LargeFileKind: (bytes: Int64, count: Int)] = [:]
        for f in base { totals[f.kind, default: (0, 0)].bytes += f.allocatedBytes; totals[f.kind, default: (0, 0)].count += 1 }
        kindTotals = totals
        rows = base.filter { filters.kinds.isEmpty || filters.kinds.contains($0.kind) }.sorted(using: sortOrder)
    }

    // MARK: Derived

    func item(for file: LargeFile) -> ScanItem {
        if let cached = items[file.path] { return cached }
        let made = LargeFileScanner.makeItem(file)
        items[file.path] = made
        return made
    }

    var allItems: [ScanItem] { (report?.files ?? []).map(item(for:)) }

    var selectedItems: [ScanItem] { selection.selectedItems(in: rows.map(item(for:))) }

    /// Σ of what the Trash would really free for the ticked rows.
    var selectedBytes: Int64 {
        let ids = Set(selectedItems.map(\.id))
        return rows.filter { ids.contains(item(for: $0).id) }.reduce(0) { $0 + ($1.reclaimableBytes ?? $1.allocatedBytes) }
    }

    /// Sidebar badge: allocated bytes of the rows you could act on right now.
    var badgeBytes: Int64 {
        rows.filter { item(for: $0).isSelectable }.reduce(0) { $0 + $1.allocatedBytes }
    }

    var inspectedFile: LargeFile? { inspectedPath.flatMap { p in rows.first { $0.path == p } } }

    /// Scope root plus its direct child folders that hold large files, biggest first.
    var folderChoices: [(path: String, name: String)] {
        guard let root = index.tree?.rootPath else { return [] }
        var bytes: [String: Int64] = [:]
        let prefix = root.hasSuffix("/") ? root : root + "/"
        for f in report?.files ?? [] where f.path.hasPrefix(prefix) {
            guard let first = f.path.dropFirst(prefix.count).split(separator: "/", omittingEmptySubsequences: true).first,
                  f.path.dropFirst(prefix.count).contains("/") else { continue }
            bytes[prefix + first, default: 0] += f.allocatedBytes
        }
        let children = bytes.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map { (path: $0.key, name: ($0.key as NSString).lastPathComponent) }
        return [(path: root, name: LargeOldCopy.shownInHome)] + children
    }

    var folderName: String {
        guard let f = filters.folder else { return LargeOldCopy.shownInHome }
        return (f as NSString).lastPathComponent
    }

    func showAllSizes() {
        filters.minBytes = .mb100
        filters.age = .any
    }

    func toggleKind(_ k: LargeFileKind) {
        if filters.kinds.contains(k) { filters.kinds.remove(k) } else { filters.kinds.insert(k) }
    }

    // MARK: Actions

    func reviewCleanup(using coordinator: CleanupCoordinator) {
        let chosen = selectedItems
        guard !chosen.isEmpty else { return }
        let pathByID = Dictionary(chosen.map { ($0.id, $0.path) }, uniquingKeysWith: { a, _ in a })
        coordinator.review(chosen) { [weak self] trashed in
            self?.removeTrashed(trashed.compactMap { pathByID[$0] })
        }
    }

    /// After a cleanup: forget the trashed files locally (no re-index) and clear the selection.
    func removeTrashed(_ paths: [String]) {
        let gone = Set(paths)
        guard var current = report, !gone.isEmpty else { selection.deselectAll(); return }
        current.files.removeAll { gone.contains($0.path) }
        report = current
        for p in gone { items[p] = nil }
        selection.deselectAll()
        if let p = inspectedPath, gone.contains(p) { inspectedPath = nil; quickLookURL = nil }
        recompute()
    }

    /// Space bar: previews the inspected row, or closes the preview. Only ever user-initiated.
    func handleSpace() {
        if quickLookURL != nil { quickLookURL = nil; return }
        guard let file = inspectedFile else { return }
        quickLookURL = URL(fileURLWithPath: file.path)
    }

    func quickLook(_ file: LargeFile) { quickLookURL = URL(fileURLWithPath: file.path) }
    func reveal(_ file: LargeFile) { finder.reveal(URL(fileURLWithPath: file.path)) }
}

extension LargeOldModel {
    /// The scanner behind the live app: builds the path guard off the main actor (it loads rule JSON), then runs the
    /// same guard and owner filter Care Scan uses.
    static func live(environment env: PathEnvironment) -> Scanning {
        { tree in
            let loaded = RuleLoader(
                environment: env, bundledRulesDirectory: CoreResources.rulesDirectoryURL, userRulesDirectory: nil,
                guardFactory: ScanGuard.loaderFactory(environment: env)).load()
            let pathGuard = try ScanGuard(environment: env, protectPatterns: loaded.protectPatterns)
            let scanner = LargeFileScanner(options: LargeFileOptions(environment: env), lastOpened: SpotlightLastOpenedProvider(),
                                           appNames: ApplicationsFolderNames.live(env), tree: { tree })
            return try await scanner.report(tree: tree, context: ScanContext(environment: env, pathGuard: pathGuard))
        }
    }
}

/// Sorts the table without key paths (their Sendable inference is awkward here): one column, one direction.
struct LargeFileComparator: SortComparator, Hashable {
    enum Column: Hashable, Sendable { case name, kind, lastOpened, size }

    var column: Column
    var order: SortOrder = .forward

    func compare(_ l: LargeFile, _ r: LargeFile) -> ComparisonResult {
        let base: ComparisonResult = switch column {
        case .name: l.name.localizedStandardCompare(r.name)
        case .kind: LargeOldCopy.kindOne(l.kind).localizedStandardCompare(LargeOldCopy.kindOne(r.kind))
        case .lastOpened: l.lastOpened < r.lastOpened ? .orderedAscending : l.lastOpened > r.lastOpened ? .orderedDescending : .orderedSame
        case .size: l.allocatedBytes < r.allocatedBytes ? .orderedAscending : l.allocatedBytes > r.allocatedBytes ? .orderedDescending : .orderedSame
        }
        let result: ComparisonResult = base == .orderedSame ? (l.path < r.path ? .orderedAscending : l.path > r.path ? .orderedDescending : .orderedSame) : base
        guard order == .reverse else { return result }
        return result == .orderedAscending ? .orderedDescending : result == .orderedDescending ? .orderedAscending : .orderedSame
    }
}
