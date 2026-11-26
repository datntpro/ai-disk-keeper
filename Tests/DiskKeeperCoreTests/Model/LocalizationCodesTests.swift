import XCTest
@testable import DiskKeeperCore

/// T49: stable codes Core exposes so the UI can word them in the user's language.
final class LocalizationCodesTests: XCTestCase {
    func testScanWarningCodeRoundTrips() throws {
        let codes: [ScanWarning.Code] = [
            .itemCapExceeded(cap: 5), .pathError(errno: EACCES), .ruleOverlap(earlierRuleID: "a.b"), .cannotSize(errno: nil),
            .cannotSize(errno: EPERM), .ruleFileInvalid(file: "x.json"), .scannerFailed(scannerID: "s"),
            .itemOverlap(earlierRuleID: "a.c"), .settingsUnreadable(backupName: nil), .settingsUnreadable(backupName: "b"),
        ]
        for c in codes {
            let w = ScanWarning(kind: .other, message: "m", code: c)
            let back = try JSONDecoder().decode(ScanWarning.self, from: JSONEncoder().encode(w))
            XCTAssertEqual(back, w)
        }
    }

    func testOldWarningJSONWithoutCodeDecodes() throws {
        let json = #"{"kind":"other","message":"old"}"#
        let w = try JSONDecoder().decode(ScanWarning.self, from: Data(json.utf8))
        XCTAssertNil(w.code)
        XCTAssertEqual(w.message, "old")
    }

    func testEveryWarningConstructionInCoreSetsACode() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/DiskKeeperCore")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var offenders: [String] = []
        for case let url as URL in files where url.pathExtension == "swift" && url.lastPathComponent != "ScanWarning.swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            var from = text.startIndex
            while let r = text.range(of: "ScanWarning(", range: from..<text.endIndex) {
                from = r.upperBound
                // The call's argument list: up to the matching close paren.
                var depth = 1, i = r.upperBound
                while i < text.endIndex, depth > 0 {
                    if text[i] == "(" { depth += 1 } else if text[i] == ")" { depth -= 1 }
                    i = text.index(after: i)
                }
                let call = String(text[r.upperBound..<i])
                if !call.contains("code:") { offenders.append(url.lastPathComponent + ": ScanWarning(" + call.prefix(60)) }
            }
        }
        XCTAssertEqual(offenders, [], "every ScanWarning built in Core needs a `code:` for the UI to localize")
    }

    func testSettingsLanguageDefaultsToSystem() throws {
        XCTAssertEqual(AppSettings.defaults.language, "system")
        let old = #"{"schemaVersion":1,"hasCompletedOnboarding":true,"projectRoots":["~"],"excludedPaths":[],"disabledTools":[]}"#
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(old.utf8))
        XCTAssertEqual(s.language, "system")
        var changed = s
        changed.language = "vi"
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(changed)).language, "vi")
    }

    func testProtectedPatternIDsAreStableSlugs() {
        XCTAssertEqual(ProtectedPattern.slug("Claude Code skills"), "claude.code.skills")
        XCTAssertEqual(ProtectedPattern.slug("1Password CLI"), "1password.cli")
        let all = ProtectedPaths.builtInAnchored + ProtectedPaths.builtInBasenames
        var byID: [String: String] = [:]
        for p in all {
            XCTAssertFalse(p.id.isEmpty)
            // Same id ⇒ same reason ignoring case ("Keychain" / "keychain").
            if let other = byID[p.id] { XCTAssertEqual(other.lowercased(), p.why.lowercased(), p.id) }
            byID[p.id] = p.why
        }
    }

    func testPathDenialExposesWhyID() {
        let d = PathDenial(path: "/x", reason: .protectedPath, matchedPattern: "~/.ssh", why: "credentials")
        XCTAssertEqual(d.whyID, "credentials")
        XCTAssertNil(PathDenial(path: "/x", reason: .unresolvable).whyID)
    }
}
