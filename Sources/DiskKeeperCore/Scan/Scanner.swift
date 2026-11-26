import Foundation

/// A source of scan items. Implementations MUST be read-only: no writes, no renames, no `git` commands
/// that take locks, no network. They report items through `sink`; the engine re-checks every item
/// with the guard and drops overlaps, so a scanner never needs to coordinate with other scanners.
public protocol Scanner: Sendable {
    /// Stable id, e.g. "rules", "worktrees". Used in warnings and progress.
    var id: String { get }
    /// Runs to completion or throws. `CancellationError` must propagate (do not swallow it).
    /// Any other thrown error becomes one `.scannerFailed` warning; items already emitted are kept.
    func scan(context: ScanContext, sink: ScanSink) async throws
    /// The only virtual-path namespace this scanner may report items under (see ``VirtualItemPath``); nil = none.
    var virtualNamespace: String? { get }
}

extension Scanner {
    public var virtualNamespace: String? { nil }
}

public struct ScannerProgress: Sendable, Hashable {
    public var candidatesFound: Int
    public var candidatesSized: Int
    public var bytesFound: Int64
    /// Candidates dropped silently because the guard denied them (stats only, never a warning).
    public var guardDropped: Int
    /// Candidates dropped silently because another user owns them.
    public var ownerDropped: Int
    public init(candidatesFound: Int = 0, candidatesSized: Int = 0, bytesFound: Int64 = 0,
                guardDropped: Int = 0, ownerDropped: Int = 0) {
        self.candidatesFound = candidatesFound
        self.candidatesSized = candidatesSized
        self.bytesFound = bytesFound
        self.guardDropped = guardDropped
        self.ownerDropped = ownerDropped
    }
}

/// Callbacks into the engine (or a test collector). All async; may suspend (actor hop).
public struct ScanSink: Sendable {
    public let item: @Sendable (ScanItem) async -> Void
    public let warning: @Sendable (ScanWarning) async -> Void
    /// Absolute (not delta) progress of THIS scanner.
    public let progress: @Sendable (ScannerProgress) async -> Void

    public init(item: @escaping @Sendable (ScanItem) async -> Void,
                warning: @escaping @Sendable (ScanWarning) async -> Void,
                progress: @escaping @Sendable (ScannerProgress) async -> Void) {
        self.item = item
        self.warning = warning
        self.progress = progress
    }
}
