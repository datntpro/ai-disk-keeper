import Foundation

/// Directory "packages" (bundles, libraries) that the index sizes exactly but never expands.
enum PackageDetector {
    static let extensions: Set<String> = [
        "app", "bundle", "framework", "plugin", "kext", "xpc", "appex", "prefpane", "saver", "qlgenerator",
        "mdimporter", "pkg", "xcarchive", "xcodeproj", "dsym", "photoslibrary", "photolibrary", "musiclibrary",
        "tvlibrary", "imovielibrary", "fcpbundle", "sparsebundle", "sparseimage", "dmgpart",
    ]

    /// True when `name` has a non-empty stem and a listed extension (case-insensitive). `.app` is not a package.
    static func isPackage(name: String) -> Bool {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return false }
        let ext = name[name.index(after: dot)...]
        return extensions.contains(ext.lowercased())
    }
}
