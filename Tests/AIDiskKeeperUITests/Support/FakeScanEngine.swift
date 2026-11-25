import DiskKeeperCore
import Foundation
@testable import AIDiskKeeperUI

/// Test double. `scripted` replays events immediately; `gated` lets the test push events and answers `cancel()`
/// with `.cancelled(partial)` like the real engine.
actor FakeScanEngine: ScanEngineProtocol {
    enum Mode { case scripted([ScanEvent]), gated }

    private let mode: Mode
    private let endsWithoutTerminal: Bool
    private var continuation: AsyncStream<ScanEvent>.Continuation?
    private var sent: [ScanItem] = []
    private(set) var scanCalls = 0
    private(set) var cancelCalls = 0

    init(_ mode: Mode, endsWithoutTerminal: Bool = false) {
        self.mode = mode
        self.endsWithoutTerminal = endsWithoutTerminal
    }

    func scan() async throws -> AsyncStream<ScanEvent> {
        scanCalls += 1
        let (stream, cont) = AsyncStream.makeStream(of: ScanEvent.self, bufferingPolicy: .unbounded)
        switch mode {
        case .scripted(let events):
            for e in events { cont.yield(e) }
            cont.finish()
        case .gated:
            continuation = cont
        }
        return stream
    }

    func send(_ event: ScanEvent) {
        if case .itemFound(let i) = event { sent.append(i) }
        continuation?.yield(event)
        switch event {
        case .finished, .cancelled: continuation?.finish()
        default: break
        }
    }

    func endStream() { continuation?.finish() }

    func cancel() async {
        cancelCalls += 1
        guard let continuation else { return }
        continuation.yield(.cancelled(ItemFixtures.result(sent, cancelled: true)))
        continuation.finish()
    }
}
