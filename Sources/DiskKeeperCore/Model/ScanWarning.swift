import Foundation

/// A non-fatal problem encountered during a scan.
public struct ScanWarning: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable, Hashable, CaseIterable {
        case permissionDenied, needsFullDiskAccess, notFound, ruleError, scannerFailed, timeout, other
    }

    public var kind: Kind
    public var path: String?
    public var ruleID: String?
    /// User-facing, English.
    public var message: String

    public init(kind: Kind, path: String? = nil, ruleID: String? = nil, message: String) {
        self.kind = kind
        self.path = path
        self.ruleID = ruleID
        self.message = message
    }
}
