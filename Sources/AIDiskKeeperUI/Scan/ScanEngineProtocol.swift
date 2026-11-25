import DiskKeeperCore

/// The seam between the UI and the scan engine, so view models can be tested with a fake.
public protocol ScanEngineProtocol: Sendable {
    func scan() async throws -> AsyncStream<ScanEvent>
    func cancel() async
}

extension ScanEngine: ScanEngineProtocol {}
