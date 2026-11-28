import DiskKeeperCore
import Foundation
import Observation

/// The SSD health card's state. One read when the Storage screen appears, cached for `ttl` (10 min). No polling.
@MainActor @Observable
final class SSDHealthModel {
    enum State: Equatable {
        case idle, loading
        case ready(SSDHealth, writtenSinceBoot: UInt64?)
        case unavailable
    }

    private(set) var state: State = .idle

    @ObservationIgnored private let reader: any SSDHealthReading
    @ObservationIgnored private let statistics: any DiskStatisticsReading
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private let ttl: TimeInterval
    @ObservationIgnored private var lastRead: Date?
    @ObservationIgnored private var task: Task<Void, Never>?

    init(reader: any SSDHealthReading = LiveSSDHealthReader(), statistics: any DiskStatisticsReading = LiveDiskStatisticsReader(),
         clock: @escaping () -> Date = Date.init, ttl: TimeInterval = 600) {
        self.reader = reader; self.statistics = statistics; self.clock = clock; self.ttl = ttl
    }

    /// Reads unless a read is running or the last one is younger than the TTL.
    func refreshIfNeeded() {
        if task != nil { return }
        if let last = lastRead, clock().timeIntervalSince(last) < ttl { return }
        lastRead = clock()
        if state == .idle { state = .loading }
        let reader = reader, statistics = statistics
        task = Task { [weak self] in
            let result = await Task.detached(priority: .utility) { () -> State in
                guard let health = reader.read() else { return .unavailable }
                return .ready(health, writtenSinceBoot: statistics.read()?.bytesWritten)
            }.value
            self?.state = result
            self?.task = nil
        }
    }

    /// Test hook: resolves when no read is running.
    func settle() async {
        while let current = task { await current.value }
    }
}
