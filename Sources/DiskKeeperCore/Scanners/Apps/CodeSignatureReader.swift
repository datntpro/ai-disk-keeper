import Foundation
import Security

public protocol CodeSignatureReading: Sendable {
    /// `.apple`, `.developerID`, `.unsigned` or `.unknown`. The App Store receipt is layered on by the scanner.
    func source(ofBundleAt path: String) -> AppSource
}

/// Reads the signature WITHOUT validating bundle contents: full validation hashes the whole bundle
/// (seconds per app). Only the signing information and the `anchor apple` requirement are evaluated.
public struct SecStaticCodeSignatureReader: CodeSignatureReading {
    public init() {}

    public func source(ofBundleAt path: String) -> AppSource {
        var staticCode: SecStaticCode?
        let created = SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &staticCode)
        guard created == errSecSuccess, let code = staticCode else { return .unknown("SecStaticCodeCreate \(created)") }

        var requirement: SecRequirement?
        if SecRequirementCreateWithString("anchor apple" as CFString, [], &requirement) == errSecSuccess,
           let requirement {
            let flags = SecCSFlags(rawValue: kSecCSDoNotValidateResources | kSecCSDoNotValidateExecutable)
            if SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess { return .apple }
        }

        var info: CFDictionary?
        let status = SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
        guard status == errSecSuccess, let dict = info as? [String: Any] else {
            return status == errSecCSUnsigned ? .unsigned : .unknown("SecCodeCopySigningInformation \(status)")
        }
        if let team = dict[kSecCodeInfoTeamIdentifier as String] as? String, !team.isEmpty {
            return .developerID(teamID: team)
        }
        return .unsigned
    }
}
