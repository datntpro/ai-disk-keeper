import DiskKeeperCore

/// The seam between `DiskIndexModel` and `DiskIndexer`, so the model is tested with a fake.
public protocol DiskIndexing: Sendable {
    func index(_ scope: DiskIndexer.Scope, progress: (@Sendable (IndexProgress) -> Void)?) async throws -> DiskTree
    func cancel() async
}

extension DiskIndexer: DiskIndexing {}

public struct DiskIndexUnavailable: Error, CustomStringConvertible {
    public init() {}
    public var description: String { "The disk indexer isn't configured." }
}
