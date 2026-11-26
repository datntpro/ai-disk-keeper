import Foundation

/// Why an app (or one of its processes) must not be asked to quit from the Uninstaller.
public enum AppQuitRefusal: String, Sendable, Codable {
    case viewOnly, appleOrSystem, selfApp, otherUser, ownershipUnknown, stateUnknown
}

/// Pure rules for "may we send a quit request to this?". Evaluated when the button is shown and again right
/// before every quit request or force quit.
public enum AppQuitPolicy {
    /// App-level: may this app be offered "Quit App" at all?
    public static func refusal(bundleID: String, teamID: String?, viewOnly: Bool, bundlePath: String,
                               selfBundleID: String?, selfBundlePath: String?) -> AppQuitRefusal? {
        if viewOnly { return .viewOnly }
        if ApplicationBundlePolicy.isAppleIdentity(bundleID: bundleID, teamID: teamID) { return .appleOrSystem }
        if let selfBundleID, PathCanonicalizer.fold(selfBundleID) == PathCanonicalizer.fold(bundleID) { return .selfApp }
        if let selfBundlePath, isInside(bundlePath, root: selfBundlePath) || isInside(selfBundlePath, root: bundlePath) {
            return .selfApp
        }
        return nil
    }

    /// Instance-level: may this process be asked to quit / force quit?
    public static func refusal(pid: pid_t, bundleID: String?, ownerUID: uid_t?, currentUID: uid_t, selfPID: pid_t,
                               location: String?, selfBundlePath: String?) -> AppQuitRefusal? {
        if pid <= 1 { return .appleOrSystem }
        if pid == selfPID { return .selfApp }
        if let bundleID, ApplicationBundlePolicy.isAppleIdentity(bundleID: bundleID, teamID: nil) { return .appleOrSystem }
        if let location, let selfBundlePath, isInside(location, root: selfBundlePath) { return .selfApp }
        guard let ownerUID else { return .ownershipUnknown }
        if ownerUID != currentUID { return .otherUser }
        return nil
    }

    private static func isInside(_ path: String, root: String) -> Bool {
        let p = PathCanonicalizer.fold(PathNormalization.lexical(path)), r = PathCanonicalizer.fold(PathNormalization.lexical(root))
        return p == r || p.hasPrefix(r + "/")
    }
}
