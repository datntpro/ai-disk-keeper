import Foundation

/// Moves an item to the Trash. Returns the resulting URL when the system reports it.
public protocol TrashAdapter: Sendable {
    func trashItem(at url: URL) throws -> URL?
}

/// `FileManager.trashItem(at:resultingItemURL:)`.
public struct FileManagerTrash: TrashAdapter {
    public init() {}

    public func trashItem(at url: URL) throws -> URL? {
        var result: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &result)
        return result as URL?
    }
}

/// Permanently removes an item (only used when permanent delete is enabled and requested).
public protocol ItemRemover: Sendable {
    func removeItem(atPath: String) throws
}

public struct FileManagerRemover: ItemRemover {
    public init() {}

    public func removeItem(atPath path: String) throws {
        try FileManager.default.removeItem(atPath: path)
    }
}

/// Answers "is the app with this bundle id running?". `nil` means unknown (callers fail closed).
public protocol RunningAppChecking: Sendable {
    func isRunning(bundleID: String) -> Bool?
    /// Is any process (helper, login item, a copy with another id) executing from inside the bundle at `path`?
    /// `nil` = unknown (fail closed).
    func isAnyProcessRunning(insideBundleAt path: String) -> Bool?
}

extension RunningAppChecking {
    /// Default: unknown, so old conformances fail closed for app bundles.
    public func isAnyProcessRunning(insideBundleAt path: String) -> Bool? { nil }
}

/// Core default: always unknown, so items with `requiresAppQuit` are blocked (`appStateUnknown`) until the
/// app target injects an NSWorkspace-based checker. DiskKeeperCore must not import AppKit.
public struct UnknownRunningApps: RunningAppChecking {
    public init() {}
    public func isRunning(bundleID: String) -> Bool? { nil }
}
