import Foundation
import os

/// The language the user picked in Settings. `system` follows the macOS language list.
public enum AppLanguage: String, Codable, Sendable, CaseIterable {
    case system, en, vi

    /// Lenient mapping from the raw string stored in `AppSettings.language`; unknown values mean `.system`.
    public init(storedValue: String) { self = AppLanguage(rawValue: storedValue) ?? .system }
}

/// Process-wide current UI language. Read from any isolation; written only by `L10n.apply(_:)`.
/// `loc()` reads it on every call, so a language change takes effect as soon as views are re-evaluated.
public enum L10n {
    struct State: Sendable {
        var language: String
        var bundle: Bundle
        var locale: Locale
        var pseudo = false
    }

    private static let state = OSAllocatedUnfairLock(initialState: resolve(.system))

    static var current: State { state.withLock { $0 } }
    public static var locale: Locale { current.locale }
    /// "en" or "vi" (a language the catalog contains).
    public static var languageCode: String { current.language }
    /// Languages the String Catalog was compiled for, e.g. ["en", "vi"].
    public static var availableLanguages: [String] {
        Bundle.module.localizations.filter { $0 != "Base" }.sorted()
    }

    public static func apply(_ choice: AppLanguage) { state.withLock { $0 = resolve(choice) } }

    /// Test and debug aid: shows English text wrapped in brackets, accented and padded by ~40 % to expose layouts
    /// that can't take longer strings. Undo with `apply(_:)`.
    public static func applyPseudo() {
        state.withLock { s in
            s = resolve(.en)
            s.pseudo = true
        }
    }

    /// Runs `body` with `choice` active, then restores the previous language. For tests (run them serialized).
    static func withLanguage<T>(_ choice: AppLanguage, _ body: () throws -> T) rethrows -> T {
        let saved = state.withLock { $0 }
        apply(choice)
        defer { state.withLock { $0 = saved } }
        return try body()
    }

    static func resolve(_ choice: AppLanguage, preferred: [String] = Locale.preferredLanguages) -> State {
        let available = Bundle.module.localizations.filter { $0 != "Base" }
        let lang: String = switch choice {
        case .system: Bundle.preferredLocalizations(from: available, forPreferences: preferred).first ?? "en"
        case .en: "en"
        case .vi: "vi"
        }
        let bundle = Bundle.module.path(forResource: lang, ofType: "lproj").flatMap(Bundle.init(path:)) ?? .module
        // Keep the user's region for .system (vi-VN, en-GB…); explicit choices use a matching region.
        let locale: Locale = choice == .system ? .autoupdatingCurrent
            : (lang == "vi" ? Locale(identifier: "vi_VN") : Locale(identifier: "en_US"))
        return State(language: lang, bundle: bundle, locale: locale)
    }

    /// "[Šçåñ ~~~~]": accents, brackets and ~40 % padding. Placeholders are already substituted when this runs.
    static func pseudoLocalize(_ s: String) -> String {
        let map: [Character: Character] = [
            "a": "å", "e": "é", "i": "î", "o": "ö", "u": "ü", "c": "ç", "n": "ñ", "s": "š", "y": "ý",
            "A": "Å", "E": "É", "I": "Î", "O": "Ö", "U": "Ü", "C": "Ç", "N": "Ñ", "S": "Š", "Y": "Ý",
        ]
        let accented = String(s.map { map[$0] ?? $0 })
        let pad = String(repeating: "~", count: max(2, Int((Double(s.count) * 0.4).rounded(.up))))
        return "[\(accented) \(pad)]"
    }
}

/// Bundle that holds the active language's strings (`en.lproj` / `vi.lproj` inside the UI resource bundle).
var uiStringsBundle: Bundle { L10n.current.bundle }

/// Looks up a user-facing string by stable key, with the English text as the default value.
/// Never hard-code user-facing text in views or models: call this. `locale:` makes interpolated numbers follow
/// the in-app language instead of the system region.
func loc(_ key: StaticString, _ defaultValue: String.LocalizationValue) -> String {
    let s = L10n.current
    let text = String(localized: key, defaultValue: defaultValue, bundle: s.bundle, locale: s.locale)
    return s.pseudo ? L10n.pseudoLocalize(text) : text
}
