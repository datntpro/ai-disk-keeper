import Darwin
import Foundation

public struct ScanContext: Sendable {
    public let environment: PathEnvironment
    public let pathGuard: ScanGuard
    /// Fixed for the whole scan: every `tierWhen` uses the same clock.
    public let now: Date
    public let userID: uid_t
    public let sizerOptions: FileSizer.Options
    public let maxConcurrentSizing: Int
    /// See docs/PERF.md for the measurements behind this default.
    public static var defaultConcurrentSizing: Int { min(8, ProcessInfo.processInfo.activeProcessorCount) }
    /// Shared by ALL scanners of one scan, so the bound is global.
    let sizingLimiter: AsyncLimiter
    /// Incremental size cache (T25). nil = every item is walked. Only the scan pipeline sets it: the cleanup engine,
    /// the item validator and the disk indexer never use it.
    public let sizeCache: SizeCache?
    /// H6 (D11): items whose first walk finds at least this many allocated bytes are walked again with the clone
    /// probe on, to learn what deleting them would really free. nil = never probe. Small items are never probed.
    public let reclaimProbeMinItemBytes: Int64?
    public static let defaultReclaimProbeMinItemBytes: Int64 = 100_000_000

    public init(environment: PathEnvironment, pathGuard: ScanGuard, now: Date = Date(),
                userID: uid_t = getuid(), sizerOptions: FileSizer.Options = .init(),
                maxConcurrentSizing: Int = ScanContext.defaultConcurrentSizing,
                sizeCache: SizeCache? = nil,
                reclaimProbeMinItemBytes: Int64? = ScanContext.defaultReclaimProbeMinItemBytes) {
        self.environment = environment
        self.pathGuard = pathGuard
        self.now = now
        self.userID = userID
        self.sizerOptions = sizerOptions
        self.maxConcurrentSizing = max(1, maxConcurrentSizing)
        self.sizingLimiter = AsyncLimiter(limit: max(1, maxConcurrentSizing))
        self.sizeCache = sizeCache
        self.reclaimProbeMinItemBytes = reclaimProbeMinItemBytes
    }

    /// Sizes one root under the shared limiter.
    ///
    /// The cache holds the plain report plus a ``ReclaimPlan`` (which files to re-check) but never the numbers that
    /// depend on state OUTSIDE the root: a clone or hard link made elsewhere later writes nothing inside it, so FSEvents
    /// cannot invalidate them. On a hit, a big item's probe fields are refreshed from the plan with one `lstat` (+
    /// `getattrlist`) per probed or multi-link file: no tree walk. Without a plan it is probed again by a walk.
    public func size(_ url: URL, progress: (@Sendable (SizeProgress) -> Void)? = nil) async throws -> SizeReport {
        if let hit = await sizeCache?.valid(url) {
            if let minBytes = reclaimProbeMinItemBytes, !sizerOptions.measurePrivateBytes,
               hit.allocatedBytes >= minBytes, hit.rootKind != .symlink {
                if let fresh = FileSizer.refreshReclaim(hit) { return fresh }
                let measured = try await withReclaim(Self.withoutReclaim(hit), url)
                return measured
            }
            return hit
        }
        // The root is stamped BEFORE the walk: a change during the walk makes the next lookup miss.
        let stamp = await sizeCache?.stamp(url)
        try await sizingLimiter.acquire()
        let report: SizeReport
        do {
            report = try await FileSizer(options: sizerOptions).size(of: url, progress: progress)
            await sizingLimiter.release()
        } catch {
            await sizingLimiter.release()
            throw error
        }
        let result = try await withReclaim(report, url)
        if let stamp { await sizeCache?.store(Self.cacheable(result), for: url, stamp: stamp) }
        return result
    }

    /// What the cache keeps: sizes and the plan, no probe numbers.
    static func cacheable(_ r: SizeReport) -> SizeReport {
        var c = withoutReclaim(r)
        c.reclaimPlan = r.reclaimPlan
        return c
    }

    /// The "frees about" fallback when the probe walk could not run: everything counts, flagged "may free less".
    static func conservative(_ r: SizeReport) -> SizeReport {
        var c = r
        c.privateBytes = r.allocatedBytes
        c.privateIsEstimate = true
        return c
    }

    static func withoutReclaim(_ r: SizeReport) -> SizeReport {
        var c = r
        c.privateBytes = nil; c.sharedOutsideBytes = 0; c.probedBytes = 0; c.privateIsEstimate = false
        c.reclaimPlan = nil
        return c
    }

    /// Size first, then walk again with the probe on, only for big items (metadata only). If that walk fails the
    /// number falls back to the conservative one: allocated bytes, marked an estimate ("may free less"); the size
    /// itself is unaffected.
    private func withReclaim(_ report: SizeReport, _ url: URL) async throws -> SizeReport {
        guard let minBytes = reclaimProbeMinItemBytes, !sizerOptions.measurePrivateBytes,
              report.allocatedBytes >= minBytes, report.rootKind != .symlink else { return report }
        var probing = sizerOptions
        probing.measurePrivateBytes = true
        try await sizingLimiter.acquire()
        do {
            var measured = try await FileSizer(options: probing).size(of: url)
            await sizingLimiter.release()
            if measured.issueCount > 0 { measured.privateIsEstimate = true }   // unreadable parts: may free less
            return measured
        } catch is CancellationError {
            await sizingLimiter.release()
            throw CancellationError()
        } catch {
            await sizingLimiter.release()
            return Self.conservative(report)
        }
    }
}
