import Foundation
@testable import DiskKeeperCore

/// Fixed snapshot (nil = unreadable). Counts calls.
final class FakeUsageSource: ProcessUsageSource, @unchecked Sendable {
    private let lock = NSLock()
    private var holds: [ProcessHold]?
    private var calls = 0
    init(_ holds: [ProcessHold]? = []) { self.holds = holds }
    var callCount: Int { lock.lock(); defer { lock.unlock() }; return calls }
    func set(_ h: [ProcessHold]?) { lock.lock(); holds = h; lock.unlock() }
    func snapshot(userID: uid_t) -> [ProcessHold]? { lock.lock(); calls += 1; defer { lock.unlock() }; return holds }
}

func setMTime(_ path: String, _ date: Date) throws {
    try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path)
}

/// Stops a child this test spawned (only that pid) without ever blocking: `waitUntilExit` can hang when the
/// process's exit notification is starved on a loaded machine.
func stopChild(_ p: Process) {
    guard p.isRunning else { return }
    p.terminate()
    for _ in 0..<30 where p.isRunning { usleep(100_000) }
    if p.isRunning { kill(p.processIdentifier, SIGKILL) }
    for _ in 0..<30 where p.isRunning { usleep(100_000) }
}
