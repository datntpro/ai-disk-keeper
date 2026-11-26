import Foundation

/// Where an app bundle was found. Only `applications` and `userApplications` are "top level".
public enum AppLocation: String, Sendable, Codable {
    case applications, applicationsUtilities, applicationsNested, userApplications, system

    public var isTopLevel: Bool { self == .applications || self == .userApplications }
}

/// Who distributed the app (read from the code signature and the App Store receipt).
public enum AppSource: Sendable, Hashable, Codable {
    /// Satisfies the requirement `anchor apple` (not `anchor apple generic`).
    case apple
    /// `Contents/_MASReceipt/receipt` exists.
    case appStore(teamID: String?)
    case developerID(teamID: String)
    /// No signature, or an ad-hoc signature.
    case unsigned
    /// The signature could not be read (reason).
    case unknown(String)

    public var teamID: String? {
        switch self {
        case .appStore(let t): t
        case .developerID(let t): t
        case .apple, .unsigned, .unknown: nil
        }
    }
}

public struct InstalledApp: Sendable, Hashable, Codable, Identifiable {
    public enum ViewOnlyReason: String, Sendable, Codable {
        case apple, systemVolume, notTopLevel, symlink, notOwnedByUser, noBundleID
    }

    public var id: String { path }
    /// Lexical, as found (never standardized).
    public let path: String
    public let bundleID: String
    /// CFBundleDisplayName ?? CFBundleName ?? file stem.
    public let name: String
    public let bundleName: String?
    public let version: String?
    public let executableName: String?
    public let location: AppLocation
    public let source: AppSource
    public let ownerUID: UInt32
    /// The `.app` entry itself is a symlink (e.g. Safari into a cryptex).
    public let isSymlink: Bool
    public let sizeAllocated: Int64
    public let sizeLogical: Int64
    public let fileCount: Int
    /// `kMDItemLastUsedDate`; nil = never or unknown.
    public let lastUsed: Date?
    public let isRunning: Bool?
    /// nil means a later uninstall step may offer `trashApplication`. This is only the scan-time verdict.
    public let viewOnlyReason: ViewOnlyReason?

    public init(path: String, bundleID: String, name: String, bundleName: String? = nil, version: String? = nil,
                executableName: String? = nil, location: AppLocation, source: AppSource, ownerUID: UInt32,
                isSymlink: Bool, sizeAllocated: Int64, sizeLogical: Int64, fileCount: Int,
                lastUsed: Date? = nil, isRunning: Bool? = nil, viewOnlyReason: ViewOnlyReason?) {
        self.path = path
        self.bundleID = bundleID
        self.name = name
        self.bundleName = bundleName
        self.version = version
        self.executableName = executableName
        self.location = location
        self.source = source
        self.ownerUID = ownerUID
        self.isSymlink = isSymlink
        self.sizeAllocated = sizeAllocated
        self.sizeLogical = sizeLogical
        self.fileCount = fileCount
        self.lastUsed = lastUsed
        self.isRunning = isRunning
        self.viewOnlyReason = viewOnlyReason
    }

    /// App-bundle item for the Applications list. It does NOT go through `ScanEngine` (the guard drops
    /// `/Applications`); the uninstall flow hands it to `CleanupEngine.plan` once the guard exception exists.
    public func makeScanItem() -> ScanItem {
        let method: CleanupMethod = viewOnlyReason == nil ? .trashApplication(bundleID: bundleID) : .none
        var flags: Set<ItemFlag> = []
        if isSymlink { flags.insert(.symlink) }
        return ScanItem(
            url: URL(fileURLWithPath: path), displayName: name, tool: .apps, category: .application,
            sizeAllocated: sizeAllocated, sizeLogical: sizeLogical, fileCount: fileCount,
            lastModified: nil, tier: .review, explanation: explanation, ruleID: "apps.bundle",
            cleanupMethod: method, requiresAppQuit: bundleID, flags: flags, groupID: "app:\(bundleID)")
    }

    private var explanation: String {
        switch viewOnlyReason {
        case .apple?: return "Part of macOS or Apple software. Shown for size only; it can't be removed here."
        case .systemVolume?: return "Lives on the protected system volume. Shown for size only."
        case .symlink?: return "A link to an app stored elsewhere. Shown for size only."
        case .notTopLevel?: return "Inside a sub-folder of Applications (a suite or vendor folder). Shown for size only."
        case .notOwnedByUser?: return "Installed for all users (not owned by you). Remove it from Finder; you may need an administrator password."
        case .noBundleID?: return "This app has no bundle identifier. Shown for size only."
        case nil:
            switch source {
            case .appStore: return "Mac App Store app. Moves to the Trash; its leftover files can be reviewed too."
            default: return "Moves to the Trash; its leftover files can be reviewed too."
            }
        }
    }
}

public struct AppInventory: Sendable {
    public let apps: [InstalledApp]
    public let warnings: [ScanWarning]
    public let scannedRoots: [String]

    public init(apps: [InstalledApp], warnings: [ScanWarning], scannedRoots: [String]) {
        self.apps = apps
        self.warnings = warnings
        self.scannedRoots = scannedRoots
    }
}
