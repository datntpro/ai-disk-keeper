import AppKit
import DiskKeeperCore

/// `RunningAppChecking` backed by `NSRunningApplication`. Thread-safe and synchronous; always a definite answer.
public struct WorkspaceRunningApps: RunningAppChecking {
    public init() {}

    public func isRunning(bundleID: String) -> Bool? {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { !$0.isTerminated }.isEmpty
    }
}
