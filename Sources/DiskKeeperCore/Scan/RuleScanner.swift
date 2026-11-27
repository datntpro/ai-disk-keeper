import Darwin
import Foundation

/// Executes JSON rules: expands each rule's `match`, drops overlaps (earlier rule wins), sizes the
/// candidates under the shared limiter and builds `ScanItem`s. Read-only.
public struct RuleScanner: Scanner {
    public let id = "rules"
    /// Load order = priority order for overlaps.
    public let rules: [ResolvedRule]

    /// TEST-ONLY: runs between expansion and sizing.
    var _afterExpand: (@Sendable () async -> Void)?

    public init(rules: [ResolvedRule]) { self.rules = rules }
    public init(loadResult: RuleLoadResult) { self.init(rules: loadResult.allRules) }

    private struct Planned: Sendable {
        let rule: ResolvedRule
        let candidate: RuleCandidate
        let project: ProjectRef?
    }

    private enum Outcome: Sendable {
        case item(ScanItem)
        case warning(ScanWarning)
        case skipped
    }

    public func scan(context: ScanContext, sink: ScanSink) async throws {
        let expansion = try await expand(context: context, sink: sink)
        let planned = expansion.planned
        let base = ScannerProgress(candidatesFound: planned.count, guardDropped: expansion.guardDropped,
                                   ownerDropped: expansion.ownerDropped)
        await sink.progress(base)
        await _afterExpand?()
        try await size(planned, base: base, context: context, sink: sink)
    }

    // MARK: Phase 1: expand (sequential, rule order)

    private struct Expansion {
        var planned: [Planned] = []
        var guardDropped = 0
        var ownerDropped = 0
    }

    private func expand(context: ScanContext, sink: ScanSink) async throws -> Expansion {
        var claims = PathClaimSet()
        var owner: [String: String] = [:]          // claimed (physical) path → rule id
        let pathResolver = SystemPathResolver()
        var parentCache: [String: String] = [:]
        var out = Expansion()
        var warnedPairs = Set<String>()
        var resolver = ClaudeProjectResolver()
        for rule in rules {
            try Task.checkCancellation()
            let result = try CandidateExpander.expand(rule, userID: context.userID, pathGuard: context.pathGuard)
            for w in result.warnings { await sink.warning(w) }
            out.guardDropped += result.guardDropped
            out.ownerDropped += result.ownerDropped
            for candidate in result.candidates {
                let physical = PhysicalPath.of(candidate.path, resolver: pathResolver, cache: &parentCache)
                if let conflict = claims.claim(physical) {
                    let claimedPath: String
                    switch conflict {
                    case .equal(let p), .inside(let p), .contains(let p): claimedPath = p
                    }
                    let earlier = owner[claimedPath] ?? "?"
                    if earlier != rule.rule.id, warnedPairs.insert(rule.rule.id + "\u{0}" + earlier).inserted {
                        await sink.warning(ScanWarning(
                            kind: .ruleError, path: candidate.path, ruleID: rule.rule.id,
                            message: "overlaps items of \(earlier); the earlier rule wins",
                            code: .ruleOverlap(earlierRuleID: earlier)))
                    }
                    continue
                }
                owner[physical] = rule.rule.id
                out.planned.append(Planned(rule: rule, candidate: candidate,
                                       project: project(for: candidate, rule: rule.rule, resolver: &resolver)))
            }
        }
        return out
    }

    private func project(for c: RuleCandidate, rule: ScannerRule, resolver: inout ClaudeProjectResolver) -> ProjectRef? {
        let comps = PathNormalization.components(c.path)
        switch rule.project {
        case .none:
            return nil
        case .itemName:
            guard let last = comps.last.map(String.init) else { return nil }
            return ProjectRef(id: "name:" + last, displayName: last)
        case .parentOfItem:
            let parent = "/" + comps.dropLast().joined(separator: "/")
            return ProjectRef(rootURL: URL(fileURLWithPath: parent))
        case .claudeProjectDirName:
            let base = PathNormalization.components(c.containerPath).count
            guard comps.count > base else { return nil }
            let name = String(comps[base])
            let dir = "/" + comps[0...base].joined(separator: "/")
            return resolver.project(forProjectDir: dir, encodedName: name)
        }
    }

    // MARK: Phase 2: size (sliding window)

    /// Throttled (≤ 4/s) live progress while single candidates are walked (#75 FU1). Called on walker
    /// threads; events go through an ordered stream so a stale one can't land after the final report.
    private final class LiveProgress: @unchecked Sendable {
        private let lock = NSLock()
        private let base: ScannerProgress
        private let continuation: AsyncStream<ScannerProgress>.Continuation
        private var completedBytes: Int64 = 0
        private var sized = 0
        private var inflight: [Int: Int64] = [:]
        private var lastEmit = Date.distantPast
        static let minInterval: TimeInterval = 0.25

        init(base: ScannerProgress, continuation: AsyncStream<ScannerProgress>.Continuation) {
            self.base = base
            self.continuation = continuation
        }

        func walked(index: Int, bytes: Int64) {
            lock.lock(); defer { lock.unlock() }
            inflight[index] = bytes
            let now = Date()
            guard now.timeIntervalSince(lastEmit) >= Self.minInterval else { return }
            lastEmit = now
            continuation.yield(snapshot())
        }

        /// A candidate finished (or failed): move its bytes from in-flight to completed.
        func done(index: Int, bytes: Int64) {
            lock.lock(); defer { lock.unlock() }
            inflight[index] = nil
            completedBytes += bytes
        }

        /// Also emits (same ≤ 4/s gate) so progress keeps flowing when candidates are small and fast.
        func setSized(_ n: Int) {
            lock.lock(); defer { lock.unlock() }
            sized = n
            let now = Date()
            guard now.timeIntervalSince(lastEmit) >= Self.minInterval else { return }
            lastEmit = now
            continuation.yield(snapshot())
        }

        private func snapshot() -> ScannerProgress {
            var p = base
            p.candidatesSized = sized
            p.bytesFound = completedBytes + inflight.values.reduce(0, +)
            return p
        }
    }

    private func size(_ planned: [Planned], base: ScannerProgress, context: ScanContext, sink: ScanSink) async throws {
        var sized = 0
        var emitted = 0
        var bytes: Int64 = 0
        let (stream, continuation) = AsyncStream<ScannerProgress>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let live = LiveProgress(base: base, continuation: continuation)
        let pump = Task { for await p in stream { await sink.progress(p) } }
        defer { continuation.finish() }
        try await withThrowingTaskGroup(of: Outcome.self) { group in
            var next = 0
            func startNext() {
                guard next < planned.count else { return }
                let p = planned[next]
                let index = next
                next += 1
                group.addTask { try await Self.sizeOne(p, context: context, index: index, live: live) }
            }
            for _ in 0..<min(context.maxConcurrentSizing, planned.count) { startNext() }
            while let outcome = try await group.next() {
                try Task.checkCancellation()
                sized += 1
                switch outcome {
                case .item(let item):
                    emitted += 1
                    bytes += item.sizeAllocated
                    await sink.item(item)
                case .warning(let w):
                    await sink.warning(w)
                case .skipped:
                    break
                }
                live.setSized(sized)
                startNext()
            }
        }
        continuation.finish()
        await pump.value
        var final = base
        final.candidatesSized = sized
        final.bytesFound = bytes
        await sink.progress(final)
    }

    private static func sizeOne(_ p: Planned, context: ScanContext, index: Int, live: LiveProgress) async throws -> Outcome {
        let path = p.candidate.path
        // `{name}`: the entry's own name is the bundle id of the app to quit. Anything else is not emitted.
        var appQuit = p.rule.rule.cleanup.requiresAppQuit
        if appQuit == RuleCleanup.namePlaceholder {
            let leaf = PathNormalization.components(path).last.map(String.init) ?? ""
            guard RuleCleanup.isValidBundleID(leaf) else { return .skipped }
            appQuit = leaf
        }
        let report: SizeReport
        do {
            report = try await context.size(URL(fileURLWithPath: path)) { live.walked(index: index, bytes: $0.allocatedBytesSoFar) }
            live.done(index: index, bytes: report.allocatedBytes)
        } catch is CancellationError {
            throw CancellationError()
        } catch FileSizerError.rootNotFound {
            live.done(index: index, bytes: 0)
            return .skipped
        } catch FileSizerError.rootInaccessible(_, let code) {
            live.done(index: index, bytes: 0)
            let kind: ScanWarning.Kind = code == EPERM ? .needsFullDiskAccess : .permissionDenied
            return .warning(ScanWarning(kind: kind, path: path, ruleID: p.rule.rule.id,
                                        message: "cannot size \(path): \(String(cString: strerror(code)))",
                                        code: .cannotSize(errno: code)))
        } catch {
            live.done(index: index, bytes: 0)
            return .warning(ScanWarning(kind: .permissionDenied, path: path, ruleID: p.rule.rule.id,
                                        message: "cannot size \(path): \(error)", code: .cannotSize(errno: nil)))
        }
        return .item(buildItem(p, report: report, now: context.now, appQuit: appQuit))
    }

    // MARK: Phase 3: build the item

    private static func buildItem(_ p: Planned, report: SizeReport, now: Date, appQuit: String?) -> ScanItem {
        let rule = p.rule.rule
        let path = p.candidate.path
        let parent = "/" + PathNormalization.components(path).dropLast().joined(separator: "/")
        var markers = Set<String>()
        for m in rule.tierWhen.compactMap(\.condition.markerExists) {
            var st = stat()
            if lstat(path + "/" + m, &st) == 0 || lstat(parent + "/" + m, &st) == 0 { markers.insert(m) }
        }
        let facts = ItemFacts(lastModified: report.newestModification,
                              sizeAllocated: report.allocatedBytes, existingMarkers: markers)
        let tier = TierEvaluator.evaluate(rule, facts: facts, now: now).tier

        var flags = Set<ItemFlag>()
        if !report.isComplete { flags.insert(.sizeIncomplete) }
        if report.issues.contains(where: { $0.kind == .notPermitted }) { flags.insert(.needsFullDiskAccess) }
        if !report.skippedMountPoints.isEmpty { flags.insert(.otherVolume) }
        if p.candidate.onOtherVolume { flags.insert(.otherVolume) }
        if report.externallyLinkedFileCount > 0 { flags.insert(.sharedStorage) }

        let name = rule.match.kind == .self
            ? rule.title : PathNormalization.components(path).last.map(String.init) ?? path
        return ScanItem(
            url: URL(fileURLWithPath: path), displayName: name, tool: p.rule.tool, category: rule.category,
            project: p.project, sizeAllocated: report.allocatedBytes, sizeLogical: report.logicalBytes,
            fileCount: report.fileCount, lastModified: report.newestModification, tier: tier,
            explanation: rule.explanation, ruleID: rule.id, cleanupMethod: rule.cleanup.cleanupMethod,
            requiresAppQuit: appQuit, flags: flags)
    }
}
