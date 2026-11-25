import Foundation

/// Cancellation-safe FIFO counting semaphore.
public actor AsyncLimiter {
    private let limit: Int
    private var inUse = 0
    private var waiters: [(id: UUID, cont: CheckedContinuation<Void, Error>)] = []

    public init(limit: Int) { self.limit = max(1, limit) }

    public func acquire() async throws {
        try Task.checkCancellation()
        if inUse < limit {
            inUse += 1
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    cont.resume(throwing: CancellationError())
                } else {
                    waiters.append((id, cont))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    public func release() {
        if waiters.isEmpty {
            inUse = max(0, inUse - 1)
        } else {
            waiters.removeFirst().cont.resume()  // slot handed over
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let i = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: i).cont.resume(throwing: CancellationError())
    }
}
