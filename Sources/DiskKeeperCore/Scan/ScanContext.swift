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

    public init(environment: PathEnvironment, pathGuard: ScanGuard, now: Date = Date(),
                userID: uid_t = getuid(), sizerOptions: FileSizer.Options = .init(),
                maxConcurrentSizing: Int = ScanContext.defaultConcurrentSizing,
                sizeCache: SizeCache? = nil) {
        self.environment = environment
        self.pathGuard = pathGuard
        self.now = now
        self.userID = userID
        self.sizerOptions = sizerOptions
        self.maxConcurrentSizing = max(1, maxConcurrentSizing)
        self.sizingLimiter = AsyncLimiter(limit: max(1, maxConcurrentSizing))
        self.sizeCache = sizeCache
    }

    /// Sizes one root under the shared limiter.
    public func size(_ url: URL, progress: (@Sendable (SizeProgress) -> Void)? = nil) async throws -> SizeReport {
        if let hit = await sizeCache?.valid(url) { return hit }
        // The root is stamped BEFORE the walk: a change during the walk makes the next lookup miss.
        let stamp = await sizeCache?.stamp(url)
        try await sizingLimiter.acquire()
        do {
            let report = try await FileSizer(options: sizerOptions).size(of: url, progress: progress)
            await sizingLimiter.release()
            if let stamp { await sizeCache?.store(report, for: url, stamp: stamp) }
            return report
        } catch {
            await sizingLimiter.release()
            throw error
        }
    }
}
