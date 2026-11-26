import AppKit
import DiskKeeperCore

/// `RunningAppChecking` backed by `NSRunningApplication`. Thread-safe and synchronous; always a definite answer.
public struct WorkspaceRunningApps: RunningAppChecking {
    public init() {}

    public func isRunning(bundleID: String) -> Bool? {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { !$0.isTerminated }.isEmpty
    }

    /// Any running application whose bundle or executable lives inside the bundle at `path`.
    public func isAnyProcessRunning(insideBundleAt path: String) -> Bool? {
        let root = (URL(fileURLWithPath: path).resolvingSymlinksInPath().path).lowercased()
        func inside(_ url: URL?) -> Bool {
            guard let p = url?.resolvingSymlinksInPath().path.lowercased() else { return false }
            return p == root || p.hasPrefix(root + "/")
        }
        return NSWorkspace.shared.runningApplications.contains {
            !$0.isTerminated && (inside($0.bundleURL) || inside($0.executableURL))
        }
    }
}
