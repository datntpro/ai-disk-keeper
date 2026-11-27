import XCTest

/// Lints Sources/AIDiskKeeperUI/Resources/Localizable.xcstrings as raw JSON. The compiler-backed check
/// (`scripts/l10n-extract.py --check`, run in CI) additionally verifies the English defaults against the code;
/// these tests give fast local feedback without a second build.
final class CatalogLintTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    private struct Entry { let key: String; let en: String?; let vi: String?; let viState: String?; let stale: Bool; let raw: [String: Any] }

    private func entries() throws -> [Entry] {
        let url = Self.root.appendingPathComponent("Sources/AIDiskKeeperUI/Resources/Localizable.xcstrings")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(json["sourceLanguage"] as? String, "en")
        let strings = try XCTUnwrap(json["strings"] as? [String: [String: Any]])
        return strings.map { key, v in
            func unit(_ lang: String) -> [String: Any]? {
                let loc = (v["localizations"] as? [String: Any])?[lang] as? [String: Any]
                // A plural key (`variations.plural`) is judged by its `other` form, which the code default must equal.
                let plural = (((loc?["variations"] as? [String: Any])?["plural"] as? [String: Any])?["other"]
                    as? [String: Any])?["stringUnit"] as? [String: Any]
                return loc?["stringUnit"] as? [String: Any] ?? plural
            }
            return Entry(key: key, en: unit("en")?["value"] as? String, vi: unit("vi")?["value"] as? String,
                         viState: unit("vi")?["state"] as? String, stale: v["extractionState"] as? String == "stale", raw: v)
        }
    }

    /// `%@`, `%lld`, `%lf`, `%1$@` … in order of the argument they consume.
    static func placeholders(_ s: String) -> [String] {
        let re = try! NSRegularExpression(pattern: #"%(?:(\d+)\$)?(?:l{0,2}[dDuUfFeEgG]|@|[sScC]|%)"#)
        var positional: [(Int, String)] = [], plain: [String] = []
        for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
            let token = String(s[Range(m.range, in: s)!])
            if token == "%%" { continue }
            let type = token.replacingOccurrences(of: #"%\d+\$"#, with: "%", options: .regularExpression)
            if let r = Range(m.range(at: 1), in: s), let n = Int(s[r]) { positional.append((n, type)) } else { plain.append(type) }
        }
        return positional.isEmpty ? plain : positional.sorted { $0.0 < $1.0 }.map(\.1)
    }

    func testEveryKeyHasEnglishAndVietnamese() throws {
        for e in try entries() {
            XCTAssertFalse((e.en ?? "").isEmpty, "\(e.key): missing en")
            XCTAssertFalse((e.vi ?? "").trimmingCharacters(in: .whitespaces).isEmpty, "\(e.key): missing vi")
            XCTAssertNotEqual(e.viState, "new", "\(e.key): vi is still untranslated")
            // needs_review is allowed here; the release checklist blocks on it.
        }
    }

    func testNoStaleKeys() throws {
        for e in try entries() { XCTAssertFalse(e.stale, "\(e.key) is stale (no longer used by code)") }
    }

    func testPlaceholdersAgree() throws {
        for e in try entries() {
            guard let en = e.en, let vi = e.vi else { continue }
            XCTAssertEqual(Self.placeholders(vi), Self.placeholders(en), "\(e.key): vi placeholders differ from en")
        }
    }

    func testTextHygiene() throws {
        for e in try entries() {
            for (lang, value) in [("en", e.en), ("vi", e.vi)] {
                guard let v = value else { continue }
                XCTAssertEqual(v, v.precomposedStringWithCanonicalMapping, "\(e.key) [\(lang)] is not NFC")
                if e.key != "status.sized", e.key != "row.a11y.quit" {   // these two start with a separator on purpose
                    XCTAssertEqual(v, v.trimmingCharacters(in: .whitespacesAndNewlines), "\(e.key) [\(lang)] has stray whitespace")
                }
            }
            if let vi = e.vi { XCTAssertFalse(vi.contains("..."), "\(e.key): use … (one character) in vi") }
        }
    }

    func testVietnameseUsesGlossaryTerms() throws {
        let byKey = Dictionary(uniqueKeysWithValues: try entries().map { ($0.key, $0.vi ?? "") })
        XCTAssertEqual(byKey["tier.safe.label"], "An toàn")
        XCTAssertEqual(byKey["tier.review.label"], "Cần xem")
        XCTAssertEqual(byKey["tier.keep.label"], "Giữ lại")
        XCTAssertEqual(byKey["action.scan"], "Quét")
        XCTAssertEqual(byKey["category.modelWeights"], "Tệp mô hình")
        XCTAssertEqual(byKey["category.worktree"], "Worktree")
        // Old-style tone placement ("xoá", "hoà") must not appear: the glossary uses the new style.
        for (k, v) in byKey {
            for old in Self.oldSpellings where Self.containsWholeWord(v, old) { XCTFail("\(k) uses old-style spelling \(old)") }
        }
    }

    func testCodeAndCatalogKeysMatch() throws {
        let sources = Self.root.appendingPathComponent("Sources/AIDiskKeeperUI")
        let re = try NSRegularExpression(pattern: #"\bloc\(\s*"([^"]+)""#)
        var used = Set<String>()
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        for case let url as URL in files where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                used.insert(String(text[Range(m.range(at: 1), in: text)!]))
            }
        }
        let catalog = Set(try entries().map(\.key))
        // protected.why.* keys are written in CoreCopy as literals too, so they are covered by the scan.
        XCTAssertEqual(used.subtracting(catalog).sorted(), [], "keys used in code but missing from the catalog (run scripts/l10n-extract.py --sync)")
        XCTAssertEqual(catalog.subtracting(used).sorted(), [], "catalog keys no code uses")
    }

    static let oldSpellings = ["xoá", "hoà", "thuỷ", "khoẻ"]

    /// Whole-word, case-insensitive match (Unicode word boundary), so "hoàn" does not trip "hoà".
    static func containsWholeWord(_ text: String, _ word: String) -> Bool {
        let t = text.precomposedStringWithCanonicalMapping
        let w = NSRegularExpression.escapedPattern(for: word.precomposedStringWithCanonicalMapping)
        guard let re = try? NSRegularExpression(pattern: "(?<![\\p{L}\\p{M}\\p{N}_])\(w)(?![\\p{L}\\p{M}\\p{N}_])",
                                                options: [.caseInsensitive]) else { return false }
        return re.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) != nil
    }

    func testOldSpellingCheckIsWholeWord() {
        XCTAssertFalse(Self.containsWholeWord("Hoàn tất", "hoà"))
        XCTAssertFalse(Self.containsWholeWord("hoàn thành", "hoà"))
        XCTAssertTrue(Self.containsWholeWord("Đã hoà vốn", "hoà"))
        XCTAssertTrue(Self.containsWholeWord("Xoá tệp", "xoá"))
        XCTAssertFalse(Self.containsWholeWord("Xóa tệp", "xoá"))
    }

    func testPlaceholderParser() {
        XCTAssertEqual(Self.placeholders("%lld selected · %@"), ["%lld", "%@"])
        XCTAssertEqual(Self.placeholders("Đã chọn %2$lld · %1$@"), ["%@", "%lld"])
        XCTAssertEqual(Self.placeholders("100%% done"), [])
    }
}
