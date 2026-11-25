import Foundation

public enum RuleSource: String, Sendable, Hashable, Codable { case bundled, user }

/// Why a rule file (or the loader as a whole) was rejected. Always names the file and, when applicable,
/// the JSON path of the offending value (`rules[2].match.glob`).
public struct RuleLoadError: Error, Sendable, Hashable, CustomStringConvertible {
    public enum Kind: String, Sendable, Hashable, Codable, CaseIterable {
        case unreadableDirectory, unreadableFile, fileTooLarge, tooManyFiles, invalidJSON, unsupportedSchemaVersion,
             unknownKey, duplicateKey, missingKey, typeMismatch, invalidValue, invalidGlob, invalidPathTemplate,
             invalidRuleID, duplicateRuleID, pathOutsideAllowedRoots, protectedPathTarget, invalidProtectPattern,
             guardUnavailable
    }

    public let kind: Kind
    /// nil for loader-global errors.
    public let file: URL?
    public let source: RuleSource?
    /// "" for file-level errors.
    public let jsonPath: String
    public let message: String

    public init(kind: Kind, file: URL?, source: RuleSource?, jsonPath: String = "", message: String) {
        self.kind = kind
        self.file = file
        self.source = source
        self.jsonPath = jsonPath
        self.message = message
    }

    /// `<file name>: <jsonPath>: <message>` (parts that are empty are omitted).
    public var description: String {
        var parts: [String] = []
        if let file { parts.append(file.lastPathComponent) }
        if !jsonPath.isEmpty { parts.append(jsonPath) }
        parts.append(message)
        return parts.joined(separator: ": ")
    }

    /// The single place `DecodingError`s become `RuleLoadError`s.
    init(decodingError error: DecodingError, file: URL?, source: RuleSource?) {
        var path = error.context?.codingPath ?? []
        let kind: Kind
        var message: String
        switch error {
        case .keyNotFound(let key, let context):
            if path.last?.stringValue == key.stringValue { path.removeLast() }
            kind = .missingKey
            message = "missing required key '\(key.stringValue)'"
            _ = context
        case .typeMismatch(_, let context), .valueNotFound(_, let context):
            kind = .typeMismatch
            message = context.debugDescription
        case .dataCorrupted(let context):
            let d = context.debugDescription
            if d.hasPrefix("unknownKey:") {
                kind = .unknownKey
                message = "unknown key '\(d.dropFirst("unknownKey:".count))'"
            } else if d.hasPrefix("invalidGlob:") {
                kind = .invalidGlob
                message = String(d.dropFirst("invalidGlob:".count))
            } else if d.hasPrefix("invalidPathTemplate:") {
                kind = .invalidPathTemplate
                message = String(d.dropFirst("invalidPathTemplate:".count))
            } else if d.hasPrefix("unsupportedSchemaVersion:") {
                kind = .unsupportedSchemaVersion
                message = "unsupported schemaVersion \(d.dropFirst("unsupportedSchemaVersion:".count))"
            } else if path.isEmpty, context.underlyingError != nil {
                kind = .invalidJSON
                message = "not valid JSON: \(d)"
            } else {
                kind = .invalidValue
                message = d
            }
        @unknown default:
            kind = .invalidValue
            message = String(describing: error)
        }
        self.init(kind: kind, file: file, source: source, jsonPath: Self.jsonPath(path), message: message)
    }

    static func jsonPath(_ codingPath: [CodingKey]) -> String {
        var out = ""
        for key in codingPath {
            if let i = key.intValue { out += "[\(i)]" } else { out += out.isEmpty ? key.stringValue : ".\(key.stringValue)" }
        }
        return out
    }
}

private extension DecodingError {
    var context: Context? {
        switch self {
        case .typeMismatch(_, let c), .valueNotFound(_, let c), .keyNotFound(_, let c), .dataCorrupted(let c): c
        @unknown default: nil
        }
    }
}
