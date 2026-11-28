import Foundation
import os

/// Moves items toward Keep when a process of the user holds them (cwd or open file) or when they changed in the last
/// hour. One process snapshot per scan. Never raises a tier; see ``ItemAdjuster``.
public struct InUseAdjuster: ItemAdjuster {
    public let name = "in-use"
    public static let recentWindow: TimeInterval = 3600
    private static let log = Logger(subsystem: "app.aidiskkeeper", category: "inuse")

    private let source: any ProcessUsageSource

    public init(source: any ProcessUsageSource) { self.source = source }

    public func adjust(_ items: [ScanItem], context: ScanContext) async -> (items: [ScanItem], warnings: [ScanWarning]) {
        let candidates = items.filter { Self.isCandidate($0) }
        guard !candidates.isEmpty else { return (items, []) }
        let started = ContinuousClock.now
        let hold = source.snapshot(userID: context.userID)
        let index = hold.map { InUseIndex($0, currentUID: context.userID) }
        let took = ContinuousClock.now - started
        Self.log.info("in-use snapshot \(took.components.seconds, privacy: .public)s+\(took.components.attoseconds / 1_000_000_000_000_000, privacy: .public)ms")

        var warnings: [ScanWarning] = []
        if index == nil {
            warnings.append(ScanWarning(kind: .other, message: "Couldn't check which apps are using files. Items were not marked in use.",
                                        code: .inUseUnknown))
        }
        let out = items.map { item -> ScanItem in
            guard Self.isCandidate(item) else { return item }
            var item = item
            if let holder = index?.holder(of: item.path) {
                item.tier = .keep
                item.flags.insert(.inUse)
                item.inUseBy = holder.name
                item.inUsePID = holder.pid
            } else if let m = item.lastModified, context.now.timeIntervalSince(m) < Self.recentWindow {
                item.tier = .keep
                item.flags.insert(.inUse)
            }
            return item
        }
        return (out, warnings)
    }

    /// Apps have their own running check; virtual items are guarded by their tool; Keep stays as it is.
    private static func isCandidate(_ item: ScanItem) -> Bool {
        if item.tier == .keep || item.isVirtual { return false }
        if case .trashApplication = item.cleanupMethod { return false }
        return true
    }
}
