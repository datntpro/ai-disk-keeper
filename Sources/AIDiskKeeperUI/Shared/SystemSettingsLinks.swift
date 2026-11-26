import Foundation

/// Deep links into System Settings.
public enum SystemSettingsLinks {
    /// Privacy & Security › App Management (`kTCCServiceSystemPolicyAppBundles`). The anchor is the section's
    /// `revealElementKeyName` in the macOS 27.2 SecurityPrivacyExtension's `TCCServiceList.plist`.
    public static let appManagement = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AppBundles")!

    /// General › Login Items & Extensions.
    public static let loginItems = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!
}
