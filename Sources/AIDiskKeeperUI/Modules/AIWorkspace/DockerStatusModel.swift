import DiskKeeperCore
import Observation

/// What the Models & Docker card shows. Detection runs off the main actor and never starts a runtime.
@MainActor @Observable
final class DockerStatusModel {
    typealias Detect = @Sendable () async -> [DockerRuntimeStatus]

    private(set) var statuses: [DockerRuntimeStatus] = []
    private(set) var isChecking = false
    @ObservationIgnored private let detect: Detect
    @ObservationIgnored private var task: Task<Void, Never>?

    init(detect: @escaping Detect) { self.detect = detect }

    /// Installed runtimes only: a runtime that isn't installed is not mentioned.
    var visible: [DockerRuntimeStatus] { statuses.filter { $0.state != .notInstalled } }

    func refresh() {
        task?.cancel()
        isChecking = true
        let detect = self.detect
        task = Task { [weak self] in
            let found = await Task.detached { await detect() }.value
            guard !Task.isCancelled else { return }
            self?.statuses = found
            self?.isChecking = false
        }
    }
}
