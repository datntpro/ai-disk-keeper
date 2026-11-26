import Darwin
import DiskKeeperCore
import Foundation
import Observation
import SwiftUI

/// State of the Duplicates screen: the finder's groups, the keep rule, manual keepers and the keep-one selection.
/// Nothing is deleted here: `reviewCleanup` hands the selection to the `CleanupCoordinator`, whose engine
/// enforces keep-one again.
@MainActor @Observable
final class DuplicatesModel {
    enum Phase: Equatable { case needsIndex, hashing(DuplicateStats?), ready, cancelled, failed(String) }

    typealias Finder = @Sendable (DiskTree, DuplicateOptions, @escaping @Sendable (DuplicateStats) -> Void) async throws -> DuplicateReport

    /// D7 menu: 1 MB (default), 10 MB, 100 MB.
    static let thresholds: [Int64] = [1_000_000, 10_000_000, 100_000_000]

    private(set) var phase: Phase = .needsIndex
    /// Finder output (members the scan guard or ownership dropped are gone), reordered by `rule` and the manual
    /// keepers, biggest savings first.
    private(set) var groups: [DuplicateGroup] = []
    private(set) var manualKeepers: [String: String] = [:]
    private(set) var selection = DuplicateSelection()
    var inspectedPath: String?
    /// Σ `group.reclaimableBytes`, kept up to date for the header and the sidebar badge.
    private(set) var totalSavings: Int64 = 0
    /// Set when the keeper can't be selected (Space on the keeper); the view announces it.
    private(set) var refusedKeeperCount = 0

    var rule: KeeperRule = .oldest {
        didSet { if rule != oldValue { reorder() } }
    }

    var minimumBytes: Int64 = 1_000_000 {
        didSet { if minimumBytes != oldValue, index.tree != nil { analyse() } }
    }

    var selectedSavings: DuplicateSavings { selection.savings }
    var selectedCount: Int { selection.count }

    let index: DiskIndexModel
    let home: String
    @ObservationIgnored private let finder: Finder
    @ObservationIgnored private let environment: PathEnvironment
    @ObservationIgnored private let guardProvider: @Sendable () async throws -> ScanGuard
    @ObservationIgnored private let userID: uid_t
    @ObservationIgnored private let makeItems: @Sendable (DuplicateReport, KeeperRule, ScanGuard, uid_t) -> [String: [ScanItem]]
    @ObservationIgnored private var baseGroups: [DuplicateGroup] = []
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var runID = 0
    @ObservationIgnored private var analysedGeneration: Int?
    @ObservationIgnored private var lastProgressAt: ContinuousClock.Instant?
    @ObservationIgnored private var lastAnnouncement: ContinuousClock.Instant?
    @ObservationIgnored private(set) var finderRuns = 0

    init(index: DiskIndexModel, finder: @escaping Finder, environment: PathEnvironment,
         guardProvider: @escaping @Sendable () async throws -> ScanGuard, userID: uid_t = getuid(),
         makeItems: @escaping @Sendable (DuplicateReport, KeeperRule, ScanGuard, uid_t) -> [String: [ScanItem]] = {
             DuplicateScanner.items(for: $0, rule: $1, pathGuard: $2, userID: $3)
         }) {
        self.makeItems = makeItems
        self.index = index
        self.finder = finder
        self.environment = environment
        self.guardProvider = guardProvider
        self.userID = userID
        self.home = environment.home
    }

    static let liveFinder: Finder = { tree, options, progress in
        try await DuplicateFinder(options: options).find(in: tree, progress: progress)
    }

    // MARK: Analysis

    /// Starts the first analysis for a new index (and only then). Called when the screen shows or the index changes.
    func refreshIfNeeded() {
        guard index.tree != nil else {
            if groups.isEmpty, phase != .hashing(nil) { phase = .needsIndex }
            return
        }
        if case .hashing = phase { return }
        if analysedGeneration != index.generation { analyse() }
    }

    func analyse() {
        guard let tree = index.tree else { phase = .needsIndex; return }
        abandon()
        runID += 1
        let id = runID
        let generation = index.generation
        phase = .hashing(nil)
        lastProgressAt = nil
        var options = DuplicateOptions(environment: environment)
        options.minimumLogicalBytes = minimumBytes
        options.keeperRule = rule
        let finder = finder, guardProvider = guardProvider, userID = userID, rule = rule, makeItems = makeItems
        finderRuns += 1
        let sink: @Sendable (DuplicateStats) -> Void = { [weak self] stats in
            Task { @MainActor in self?.receive(stats, run: id) }
        }
        let work = Task.detached(priority: .utility) { () throws -> (DuplicateReport, [String: [ScanItem]]) in
            let report = try await finder(tree, options, sink)
            try Task.checkCancellation()
            let pathGuard = try await guardProvider()
            let items = makeItems(report, rule, pathGuard, userID)
            return (report, items)
        }
        task = Task { [weak self] in
            let outcome = await withTaskCancellationHandler { await work.result } onCancel: { work.cancel() }
            guard let self, self.runID == id else { return }
            switch outcome {
            case .success(let (report, items)):
                self.apply(report: report, allowed: items)
                self.analysedGeneration = generation
                self.phase = .ready
            case .failure(let error):
                self.phase = error is CancellationError ? .cancelled : .failed(String(describing: error))
            }
            self.task = nil
        }
    }

    /// Stops the run. The previous results stay on screen.
    func cancel() {
        guard case .hashing = phase else { return }
        abandon()
        runID += 1
        phase = .cancelled
    }

    private func abandon() {
        task?.cancel()
        task = nil
    }

    private func receive(_ stats: DuplicateStats, run: Int) {
        guard run == runID, case .hashing = phase else { return }
        let now = ContinuousClock.now
        if let last = lastProgressAt, now - last < .milliseconds(100) { return }   // at most 10 Hz
        lastProgressAt = now
        phase = .hashing(stats)
    }

    /// Keeps only the members that survived the guard and ownership filter; drops groups left with fewer than two.
    private func apply(report: DuplicateReport, allowed: [String: [ScanItem]]) {
        var base: [DuplicateGroup] = []
        base.reserveCapacity(report.groups.count)
        for group in report.groups {
            guard let items = allowed[group.id] else { continue }
            let ok = Set(items.map(\.path))
            let members = group.members.filter { ok.contains($0.path) }
            guard members.count >= 2 else { continue }
            base.append(members.count == group.members.count ? group
                        : DuplicateGroup(digest: group.digest, partialDigest: group.partialDigest,
                                         logicalBytes: group.logicalBytes, members: members))
        }
        baseGroups = base
        let alive = Set(base.map(\.id))
        manualKeepers = manualKeepers.filter { alive.contains($0.key) }
        selection.clear()
        inspectedPath = nil
        reorder()
    }

    // MARK: Order

    /// Re-applies the keep rule and the manual keepers to the cached groups. Never hashes anything.
    func reorder() {
        var out: [DuplicateGroup] = []
        out.reserveCapacity(baseGroups.count)
        let rule = rule
        for base in baseGroups {
            var g = base.reordered(by: rule)
            if let path = manualKeepers[g.id] {
                if let moved = g.reordered(keeper: path) { g = moved } else { manualKeepers[g.id] = nil }
            }
            out.append(g)
        }
        out.sort { a, b in
            let x = a.reclaimableBytes, y = b.reclaimableBytes
            if x != y { return x > y }
            if a.logicalBytes != b.logicalBytes { return a.logicalBytes > b.logicalBytes }
            return a.id < b.id
        }
        groups = out
        totalSavings = out.reduce(0) { $0 + $1.reclaimableBytes }
        for id in Array(selection.selected.keys) {
            if let g = group(id: id) { selection.groupChanged(g) } else { selection.removeGroup(id) }
        }
    }

    // MARK: Lookup

    func group(id: String) -> DuplicateGroup? { groups.first { $0.id == id } }

    func group(containing path: String) -> DuplicateGroup? { groups.first { $0.members.contains { $0.path == path } } }

    /// The `ScanItem` for one member of the group as it is now ordered (the keeper carries `suggestedKeeper`).
    /// Built on demand: a rule change never rebuilds items for the whole list.
    func item(for member: DuplicateMember, in group: DuplicateGroup) -> ScanItem {
        DuplicateScanner.makeItem(member, group: group, keeper: group.keeper, rule: rule)
    }

    func isKeeper(_ member: DuplicateMember, in group: DuplicateGroup) -> Bool { member.path == group.keeper.path }

    func isManualKeeper(_ group: DuplicateGroup) -> Bool { manualKeepers[group.id] != nil }

    func canSelect(_ member: DuplicateMember, in group: DuplicateGroup) -> Bool {
        selection.canSelect(member.path, in: group, actionable: isActionable(member, in: group))
    }

    func isSelected(_ member: DuplicateMember, in group: DuplicateGroup) -> Bool {
        selection.isSelected(member.path, in: group.id)
    }

    private func isActionable(_ member: DuplicateMember, in group: DuplicateGroup) -> Bool {
        item(for: member, in: group).cleanupMethod.isActionable
    }

    /// Selected items in screen order (groups, then members).
    var selectedItems: [ScanItem] {
        var out: [ScanItem] = []
        for g in groups {
            let paths = selection.selectedPaths(in: g.id)
            guard !paths.isEmpty else { continue }
            out += g.members.filter { paths.contains($0.path) }.map { item(for: $0, in: g) }
        }
        return out
    }

    // MARK: Actions

    func toggle(_ member: DuplicateMember, in group: DuplicateGroup) {
        let actionable = isActionable(member, in: group)
        if isKeeper(member, in: group) { refusedKeeperCount += 1 }
        guard selection.toggle(member.path, in: group, actionable: actionable) else { return }
        announceSavings()
    }

    /// Space on a row: refuses the keeper and counts it so the view can announce why.
    func toggle(path: String) {
        guard let group = group(containing: path), let member = group.members.first(where: { $0.path == path }) else { return }
        toggle(member, in: group)
    }

    /// "Keep this one instead": makes `path` the group's keeper and unselects it.
    func keepInstead(_ path: String, in groupID: String) {
        guard let at = groups.firstIndex(where: { $0.id == groupID }), groups[at].keeper.path != path,
              let g = groups[at].reordered(keeper: path) else { return }
        manualKeepers[groupID] = path
        let before = groups[at].reclaimableBytes
        groups[at] = g
        totalSavings += g.reclaimableBytes - before
        selection.groupChanged(g)
        announceSavings()
    }

    // MARK: Cleanup

    /// Hands the selection to the one cleanup sheet. Deletion happens only through the coordinator's engine, which
    /// re-checks keep-one (`wouldRemoveAllCopies`, `survivorChanged`, `duplicateGroupUnknown`).
    func reviewCleanup(using coordinator: CleanupCoordinator) {
        let items = selectedItems
        guard !items.isEmpty else { return }
        var needed: [String: DuplicateGroup] = [:]
        for item in items {
            if let id = item.groupID, let g = group(id: id) { needed[id] = g }
        }
        coordinator.review(items, duplicateGroups: needed, onRescan: { [weak self] in self?.analyse() }) { [weak self] trashed in
            self?.finished(trashed: trashed)
        }
    }

    /// Removes trashed copies, drops groups left with fewer than two, clears the selection.
    func finished(trashed: Set<ScanItem.ID>) {
        guard !trashed.isEmpty else { return }
        var trashedPaths = Set<String>()
        for g in groups { for m in g.members where trashed.contains(item(for: m, in: g).id) { trashedPaths.insert(m.path) } }
        var next: [DuplicateGroup] = []
        for g in baseGroups {
            let members = g.members.filter { !trashedPaths.contains($0.path) }
            guard members.count >= 2 else { continue }
            next.append(members.count == g.members.count ? g
                        : DuplicateGroup(digest: g.digest, partialDigest: g.partialDigest,
                                         logicalBytes: g.logicalBytes, members: members))
        }
        baseGroups = next
        let alive = Set(next.map(\.id))
        manualKeepers = manualKeepers.filter { alive.contains($0.key) }
        selection.clear()
        if let p = inspectedPath, trashedPaths.contains(p) { inspectedPath = nil }
        reorder()
    }

    // MARK: Accessibility

    private func announceSavings() {
        let now = ContinuousClock.now
        if let last = lastAnnouncement, now - last < .milliseconds(500) { return }
        lastAnnouncement = now
        let text = DuplicatesCopy.selectedCount(selection.count) + ", " + SizeText.string(selection.savings.certainBytes, .upTo)
        AccessibilityNotification.Announcement(text).post()
    }
}
