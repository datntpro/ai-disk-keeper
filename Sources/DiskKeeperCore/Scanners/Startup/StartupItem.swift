import Foundation

/// One launch agent or daemon plist, as the Startup Items screen shows it. Pure data.
public struct StartupItem: Sendable, Hashable, Codable, Identifiable {
    /// Where the plist lives: `~/Library/LaunchAgents`, `/Library/LaunchAgents` or `/Library/LaunchDaemons`.
    public enum Domain: String, Sendable, Codable, CaseIterable { case userAgent, systemAgent, systemDaemon }
    public enum Schedule: Sendable, Hashable, Codable { case atLoad, keepAlive, interval(seconds: Int), calendar, onDemand }
    public enum LoadState: Sendable, Hashable, Codable { case running(pid: Int32), loaded, notLoaded, unknown }
    /// `unresolvable`: no Program/ProgramArguments, a relative path, or a bundle-relative program. Not "broken".
    public enum ProgramState: String, Sendable, Codable { case present, missing, unresolvable }

    public var id: String { plistPath }
    /// Lexical path of the plist.
    public let plistPath: String
    /// nil → the plist could not be read or has no `Label` (see `parseError`).
    public let label: String?
    /// `Program`, else `ProgramArguments[0]`.
    public let program: String?
    public let arguments: [String]
    public let schedules: [Schedule]
    public let domain: Domain
    public let programState: ProgramState
    public let signer: AppSource?
    public let loadState: LoadState
    /// The label starts with `homebrew.mxcl.`: managed by `brew services`.
    public let isHomebrewService: Bool
    /// English, for logs; the UI words it itself.
    public let parseError: String?
    public let ownerUID: UInt32
    /// The plist itself is a symlink.
    public let isSymlink: Bool
    /// `ownerUID` is the user running the app.
    public let ownedByUser: Bool
    public let lastModified: Date?
    public let allocatedBytes: Int64
    public let logicalBytes: Int64
    /// `Program` is a bundle-relative `BundleProgram` (SMAppService): managed by an app, never broken.
    public let isBundleManaged: Bool

    public init(plistPath: String, label: String?, program: String?, arguments: [String] = [], schedules: [Schedule] = [],
                domain: Domain, programState: ProgramState, signer: AppSource? = nil, loadState: LoadState = .unknown,
                isHomebrewService: Bool = false, parseError: String? = nil, ownerUID: UInt32 = 0,
                isSymlink: Bool = false, ownedByUser: Bool = true, lastModified: Date? = nil,
                allocatedBytes: Int64 = 0, logicalBytes: Int64 = 0, isBundleManaged: Bool = false) {
        self.plistPath = plistPath
        self.label = label
        self.program = program
        self.arguments = arguments
        self.schedules = schedules
        self.domain = domain
        self.programState = programState
        self.signer = signer
        self.loadState = loadState
        self.isHomebrewService = isHomebrewService
        self.parseError = parseError
        self.ownerUID = ownerUID
        self.isSymlink = isSymlink
        self.ownedByUser = ownedByUser
        self.lastModified = lastModified
        self.allocatedBytes = allocatedBytes
        self.logicalBytes = logicalBytes
        self.isBundleManaged = isBundleManaged
    }

    /// The only actionable case: a user agent whose program is gone, owned by the user, not a symlink, with a label.
    public var isRemovable: Bool {
        domain == .userAgent && programState == .missing && ownedByUser && !isSymlink && label != nil
            && parseError == nil
    }

    /// File name without `.plist`, for items with no label.
    public var fileName: String { (plistPath as NSString).lastPathComponent }
    public var displayName: String { label ?? fileName }

    /// The cleanup description. Only a removable item is trashable; every other item is report-only.
    public func makeScanItem() -> ScanItem {
        let removable = isRemovable
        let explanation = removable
            ? "Starts \(program ?? displayName), which no longer exists. Removing this file only stops macOS trying to launch it."
            : "Installed for all users or managed elsewhere. Change it in System Settings › Login Items, or with the app that installed it."
        return ScanItem(
            url: URL(fileURLWithPath: plistPath), displayName: displayName, tool: .apps, category: .startupItem,
            sizeAllocated: allocatedBytes, sizeLogical: logicalBytes, fileCount: 1, lastModified: lastModified,
            tier: removable ? .safe : .keep, explanation: explanation,
            ruleID: removable ? "startup.brokenAgent" : "startup.viewOnly",
            cleanupMethod: removable ? .trash : .none)
    }
}

public struct StartupInventory: Sendable {
    public let items: [StartupItem]
    public let warnings: [ScanWarning]
    public init(items: [StartupItem], warnings: [ScanWarning]) {
        self.items = items
        self.warnings = warnings
    }
}

public struct StartupRoots: Sendable, Hashable {
    public var userAgents: String
    public var systemAgents: String
    public var systemDaemons: String

    public init(userAgents: String, systemAgents: String, systemDaemons: String) {
        self.userAgents = userAgents
        self.systemAgents = systemAgents
        self.systemDaemons = systemDaemons
    }

    public static func live(_ env: PathEnvironment) -> StartupRoots {
        StartupRoots(userAgents: env.home + "/Library/LaunchAgents", systemAgents: "/Library/LaunchAgents",
                     systemDaemons: "/Library/LaunchDaemons")
    }
}
