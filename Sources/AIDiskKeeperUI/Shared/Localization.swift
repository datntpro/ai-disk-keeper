import Foundation

/// Bundle that holds the UI's String Catalog. T49 adds `Localizable.xcstrings` as a resource of this target and
/// points this at `.module`; until then lookups fall back to the English default value.
let uiStringsBundle: Bundle = .main

/// Looks up a user-facing string by stable key, with the English text as the default value.
/// Never hard-code user-facing text in views or models: call this (or use a `LocalizedStringKey` view API).
func loc(_ key: StaticString, _ defaultValue: String.LocalizationValue) -> String {
    String(localized: key, defaultValue: defaultValue, bundle: uiStringsBundle)
}
