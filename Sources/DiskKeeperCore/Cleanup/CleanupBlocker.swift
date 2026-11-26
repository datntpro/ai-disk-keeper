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
        }
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
        case .wouldRemoveAllCopies: "Every copy in this duplicate group is selected. Keep at least one."
        case .survivorChanged: "The copy you're keeping changed or disappeared. Rescan before deleting this duplicate."
        case .duplicateGroupUnknown: "Duplicate details are missing. Rescan and review the group."
        }
    }
}
