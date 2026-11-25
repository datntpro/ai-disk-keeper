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
    /// Shared by ALL scanners of one scan, so the bound is global.
    let sizingLimiter: AsyncLimiter

    public init(environment: PathEnvironment, pathGuard: ScanGuard, now: Date = Date(),
                userID: uid_t = getuid(), sizerOptions: FileSizer.Options = .init(),
                maxConcurrentSizing: Int = ProcessInfo.processInfo.activeProcessorCount) {
        self.environment = environment
        self.pathGuard = pathGuard
        self.now = now
        self.userID = userID
        self.sizerOptions = sizerOptions
        self.maxConcurrentSizing = max(1, maxConcurrentSizing)
        self.sizingLimiter = AsyncLimiter(limit: max(1, maxConcurrentSizing))
    }

    /// Sizes one root under the shared limiter.
    public func size(_ url: URL) async throws -> SizeReport {
        try await sizingLimiter.acquire()
        do {
            let report = try await FileSizer(options: sizerOptions).size(of: url)
            await sizingLimiter.release()
            return report
        } catch {
            await sizingLimiter.release()
            throw error
        }
    }
}
