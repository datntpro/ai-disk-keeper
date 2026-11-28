import Foundation

public enum CleanupAction: String, Codable, Sendable, Hashable {
    case trash, deletePermanently
}

/// Identity of a filesystem object taken at plan time.
public struct ItemFingerprint: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable { case directory, file, other }
    public let device: Int32
    public let inode: UInt64
    public let kind: Kind
    public let ownerUID: UInt32

    public init(device: Int32, inode: UInt64, kind: Kind, ownerUID: UInt32) {
        self.device = device
        self.inode = inode
        self.kind = kind
        self.ownerUID = ownerUID
    }
}

public struct ChangeTolerance: Sendable, Hashable, Codable {
    /// Newest mtime may be at most this much later than scanned.
    public var mtimeSlack: TimeInterval = 2
    /// Allowed |Δ allocated| is `max(sizeSlackBytes, sizeSlackFraction × scanned)`.
    public var sizeSlackBytes: Int64 = 1 << 20
    public var sizeSlackFraction: Double = 0.05
    public static let `default` = ChangeTolerance()

    public init(mtimeSlack: TimeInterval = 2, sizeSlackBytes: Int64 = 1 << 20, sizeSlackFraction: Double = 0.05) {
        self.mtimeSlack = mtimeSlack
        self.sizeSlackBytes = sizeSlackBytes
        self.sizeSlackFraction = sizeSlackFraction
    }
}

public struct ChangeDetail: Codable, Sendable, Hashable {
    public let scannedBytes: Int64
    public let currentBytes: Int64
    public let scannedModified: Date?
    public let currentModified: Date?

    public init(scannedBytes: Int64, currentBytes: Int64, scannedModified: Date?, currentModified: Date?) {
        self.scannedBytes = scannedBytes
        self.currentBytes = currentBytes
        self.scannedModified = scannedModified
        self.currentModified = currentModified
    }
}

extension Array where Element == CleanupBlocker {
    /// Same blockers once, first occurrence wins (policy + validator can both report one).
    func uniqued() -> [CleanupBlocker] {
        var seen: [CleanupBlocker] = []
        for b in self where !seen.contains(b) { seen.append(b) }
        return seen
    }
}

/// A reason an item will not be cleaned.
public enum CleanupBlocker: Codable, Sendable, Hashable {
    case keepTier
    case notActionable
    case methodNotSupported(String)
    /// `pattern` and `whyID` (optional, so older audit lines still decode) let a UI word the denial itself.
    case protectedPath(PathDenial.Reason, message: String, pattern: String? = nil, whyID: String? = nil)
    case missing
    case isSymlink
    case notOwnedByUser(uid: UInt32)
    case symlinkInParentChain(resolvedParent: String)
    case identityChanged
    case changedSinceScan(ChangeDetail)
    case appRunning(bundleID: String)
    case appStateUnknown(bundleID: String)
    case nestedInAnotherItem(otherItemID: String)
    case duplicate
    case permanentDeleteDisabled
    case sizingFailed(String)
    /// Every copy of a duplicate group is selected: at least one must stay.
    case wouldRemoveAllCopies(groupID: String)
    /// The copy that was to be kept changed or disappeared between plan and execute.
    case survivorChanged(groupID: String)
    /// A duplicate item without its group (plan(_:) without groups): fail closed.
    case duplicateGroupUnknown(groupID: String)
    /// `ApplicationBundlePolicy` refused an app bundle (see ``AppBundleRefusal``).
    case appBundleRefused(AppBundleRefusal)
    /// Root- or other-owned app (typical App Store install): remove it in Finder, there is no helper.
    case requiresAdmin(bundleID: String)
    /// The Trash move failed with `EPERM`: macOS App Management (TCC) has not been allowed.
    case needsAppManagementPermission(bundleID: String)
    /// A `.toolCommand` item but no performer is installed (fail closed).
    case toolCommandUnavailable
    /// The audit intent line for a tool command could not be written, so the command was not run.
    case auditIntentNotWritten
    /// The command is not on the compiled-in allowlist, or does not match its item (JSON rules land here).
    case toolCommandNotAllowed(reason: String)
    /// The tool's executable is missing or failed the safety checks (or changed since the dry run).
    case toolUnavailable(tool: String)
    /// The tool's service (a container runtime, say) is not running.
    case toolNotRunning(tool: String, target: String)
    /// The tool reports the object is in use now.
    case inUseByTool(detail: String)
    /// A process of the user holds the item (working directory or open file).
    case inUse(process: String, pid: Int32)
    /// The process list could not be read, so "in use" can't be ruled out (fail closed).
    case inUseUnknown
    /// The newest file inside changed less than an hour ago.
    case modifiedRecently

    /// Stable machine code used in audit lines and tests.
    public var code: String {
        switch self {
        case .keepTier: "keepTier"
        case .notActionable: "notActionable"
        case .methodNotSupported: "methodNotSupported"
        case .protectedPath: "protectedPath"
        case .missing: "missing"
        case .isSymlink: "isSymlink"
        case .notOwnedByUser: "notOwnedByUser"
        case .symlinkInParentChain: "symlinkInParentChain"
        case .identityChanged: "identityChanged"
        case .changedSinceScan: "changedSinceScan"
        case .appRunning: "appRunning"
        case .appStateUnknown: "appStateUnknown"
        case .nestedInAnotherItem: "nestedInAnotherItem"
        case .duplicate: "duplicate"
        case .permanentDeleteDisabled: "permanentDeleteDisabled"
        case .sizingFailed: "sizingFailed"
        case .wouldRemoveAllCopies: "wouldRemoveAllCopies"
        case .survivorChanged: "survivorChanged"
        case .duplicateGroupUnknown: "duplicateGroupUnknown"
        case .appBundleRefused: "appBundleRefused"
        case .requiresAdmin: "requiresAdmin"
        case .needsAppManagementPermission: "needsAppManagementPermission"
        case .toolCommandUnavailable: "toolCommandUnavailable"
        case .auditIntentNotWritten: "auditIntentNotWritten"
        case .toolCommandNotAllowed: "toolCommandNotAllowed"
        case .toolUnavailable: "toolUnavailable"
        case .toolNotRunning: "toolNotRunning"
        case .inUseByTool: "inUseByTool"
        case .inUse: "inUse"
        case .inUseUnknown: "inUseUnknown"
        case .modifiedRecently: "modifiedRecently"
        }
    }

    /// The code written to the audit log's `reasons`: `appBundleRefused:<refusal>` keeps each refusal distinguishable.
    public var auditReason: String {
        if case .appBundleRefused(let r) = self { return "appBundleRefused:\(r.rawValue)" }
        return code
    }

    /// User-facing English.
    public var message: String {
        switch self {
        case .keepTier: "Marked Keep: this is never cleaned."
        case .notActionable: "Report only: there is no cleanup action for this item."
        case .methodNotSupported(let m): "Cleanup method '\(m)' is not supported yet."
        case .protectedPath(_, let message, _, _): message
        case .missing: "The item no longer exists."
        case .isSymlink: "The item is now a symbolic link."
        case .notOwnedByUser: "The item is not owned by you."
        case .symlinkInParentChain(let p): "A parent folder is a symbolic link (resolves to \(p))."
        case .identityChanged: "The item was replaced after it was scanned."
        case .changedSinceScan: "The item changed after it was scanned. Rescan to review it again."
        case .appRunning(let b): "\(b) is running. Quit it first."
        case .appStateUnknown(let b): "Could not tell whether \(b) is running."
        case .nestedInAnotherItem: "The item overlaps another selected item."
        case .duplicate: "The item was selected more than once."
        case .permanentDeleteDisabled: "Permanent delete is turned off in Settings."
        case .sizingFailed(let e): "Could not re-measure the item: \(e)"
        case .wouldRemoveAllCopies: "No copy of this duplicate group would be left. Keep at least one."
        case .survivorChanged: "The copy you're keeping changed or disappeared. Rescan before deleting this duplicate."
        case .duplicateGroupUnknown: "Duplicate details are missing. Rescan and review the group."
        case .appBundleRefused(let r): "This app can't be removed here (\(r.rawValue))."
        case .requiresAdmin: "Installed for all users. Drag it to the Trash in Finder (you may need an administrator password)."
        case .needsAppManagementPermission: "macOS blocked this. Allow AI Disk Keeper in System Settings › Privacy & Security › App Management, then try again."
        case .toolCommandUnavailable: "Cleaning this item with its own tool isn't available."
        case .auditIntentNotWritten: "The command was not run: the audit log couldn't record it first."
        case .toolCommandNotAllowed: "This command isn't on the list of commands AI Disk Keeper may run, so it was left alone."
        case .toolUnavailable(let t): "\(t) wasn't found or isn't safe to run."
        case .toolNotRunning(let t, _): "\(t) isn't running."
        case .inUseByTool: "The tool says this is in use right now."
        case .inUse(let p, _): "In use by \(p)."
        case .inUseUnknown: "Could not tell whether something is using this."
        case .modifiedRecently: "Modified in the last hour."
        }
    }
}
