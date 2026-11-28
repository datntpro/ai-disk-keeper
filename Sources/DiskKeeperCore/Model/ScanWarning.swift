import Foundation

/// A non-fatal problem encountered during a scan.
public struct ScanWarning: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable, Hashable, CaseIterable {
        case permissionDenied, needsFullDiskAccess, notFound, ruleError, scannerFailed, timeout, other
    }

    /// Stable identifier of what happened, so a UI can word it in the user's language. `message` stays the English
    /// text for the CLI and logs. Optional so older saved results (without a code) still decode.
    public enum Code: Codable, Sendable, Hashable {
        case itemCapExceeded(cap: Int)
        case pathError(errno: Int32)
        case ruleOverlap(earlierRuleID: String)
        case cannotSize(errno: Int32?)
        case ruleFileInvalid(file: String)
        case scannerFailed(scannerID: String)
        case itemOverlap(earlierRuleID: String)
        case settingsUnreadable(backupName: String?)
        /// An app was left out of the inventory.
        case appSkipped(reason: AppSkipReason)
        /// Some files inside an item couldn't be read, so its size may be too low.
        case sizeIncomplete
        /// The process list could not be read, so no item was checked for being in use.
        case inUseUnknown
        /// An adjuster tried to do more than lower an item toward Keep; its changes were discarded.
        case adjusterRejected(name: String)
    }

    public enum AppSkipReason: String, Codable, Sendable, Hashable { case noInfoPlist, damagedInfoPlist, noBundleID }

    public var kind: Kind
    public var path: String?
    public var ruleID: String?
    /// English text (CLI, logs). UIs prefer `code` when present.
    public var message: String
    public var code: Code?

    public init(kind: Kind, path: String? = nil, ruleID: String? = nil, message: String, code: Code? = nil) {
        self.kind = kind
        self.path = path
        self.ruleID = ruleID
        self.message = message
        self.code = code
    }
}
