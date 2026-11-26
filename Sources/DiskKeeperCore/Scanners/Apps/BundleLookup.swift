import CoreServices
import Foundation

public protocol BundleLookup: Sendable {
    /// True/false when known; nil = unknown, which callers treat as "not an orphan".
    func isInstalledAnywhere(bundleID: String) -> Bool?
}

/// LaunchServices lookup: is any app with this bundle id registered anywhere (other volumes, other folders)?
public struct LaunchServicesBundleLookup: BundleLookup {
    public init() {}

    public func isInstalledAnywhere(bundleID: String) -> Bool? {
        var error: Unmanaged<CFError>?
        guard let urls = LSCopyApplicationURLsForBundleIdentifier(bundleID as CFString, &error) else {
            guard let e = error?.takeRetainedValue() else { return false }
            return CFErrorGetCode(e) == Int(kLSApplicationNotFoundErr) ? false : nil
        }
        let list = urls.takeRetainedValue() as NSArray
        return list.count > 0
    }
}
