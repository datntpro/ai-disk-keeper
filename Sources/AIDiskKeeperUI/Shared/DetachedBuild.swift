import Foundation

/// A throwing build that runs off the main actor (rule loading reads JSON from disk) and can be cancelled: cancelling the
/// awaiting task, calling `cancel()`, or releasing the last reference all cancel it. A build that has not started its
/// closure yet never runs it.
final class DetachedBuild<Value: Sendable>: Sendable {
    private let task: Task<Value, Error>

    init(_ make: @escaping @Sendable () throws -> Value) {
        task = Task.detached {
            try Task.checkCancellation()
            return try make()
        }
    }

    func value() async throws -> Value {
        try await withTaskCancellationHandler { try await task.value } onCancel: { [task] in task.cancel() }
    }

    func cancel() { task.cancel() }

    deinit { task.cancel() }
}

/// Cancels a build when its owner releases it. The awaiting task keeps the build itself alive, so the owner holds this
/// guard instead: when the owner goes away the build is cancelled even though the task still references it.
final class CancelOnRelease: Sendable {
    private let cancelBuild: @Sendable () -> Void
    init<Value>(_ build: DetachedBuild<Value>) { cancelBuild = { build.cancel() } }
    deinit { cancelBuild() }
}
