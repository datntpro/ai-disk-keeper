import Foundation

public protocol InstalledAppNamesProviding: Sendable {
    /// Normalized names (see ``ApplicationsFolderNames/normalize(_:)``) of the installed apps.
    func names() -> [String: String]
}

/// Top-level `*.app` names in `/Applications` and `~/Applications` (`contentsOfDirectory` only; bundles are
/// never opened). Returns normalized name → display name.
public struct ApplicationsFolderNames: InstalledAppNamesProviding {
    private let folders: [String]

    public init(folders: [String]) { self.folders = folders }

    public static func live(_ env: PathEnvironment) -> ApplicationsFolderNames {
        ApplicationsFolderNames(folders: ["/Applications", env.home + "/Applications"])
    }

    public func names() -> [String: String] {
        var out: [String: String] = [:]
        for folder in folders {
            for entry in (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [] where entry.hasSuffix(".app") {
                let display = String(entry.dropLast(4))
                let key = Self.normalize(display)
                if !key.isEmpty, out[key] == nil { out[key] = display }
            }
        }
        return out
    }

    private static let noiseWords: Set<String> = [
        "installer", "setup", "universal", "arm64", "x64", "intel", "mac", "macos", "osx", "dmg", "app",
    ]

    /// Lowercase, diacritics folded, separators dropped, version tokens (`16.2`, `v3`) and installer noise
    /// words (`installer`, `universal`, `arm64`, `macos`…) removed.
    public static func normalize(_ s: String) -> String {
        let folded = s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let tokens = folded.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "." })
        var kept: [String] = []
        for raw in tokens {
            let token = raw.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            if token.isEmpty || noiseWords.contains(token) || isVersion(token) { continue }
            kept.append(token.replacingOccurrences(of: ".", with: ""))
        }
        return kept.joined()
    }

    private static func isVersion(_ t: String) -> Bool {
        let body = t.hasPrefix("v") ? String(t.dropFirst()) : t
        guard let first = body.first, first.isNumber else { return false }
        return body.allSatisfy { $0.isNumber || $0 == "." }
    }

    /// Hint only. Equal, or the app name (≥ 4 characters) is a prefix of the file's stem
    /// (`DockerDesktop` for "Docker"). `Dock` never matches "Docker".
    public static func match(stem: String, in apps: [String: String]) -> String? {
        let key = normalize(stem)
        guard !key.isEmpty else { return nil }
        if let hit = apps[key] { return hit }
        return apps.filter { $0.key.count >= 4 && key.hasPrefix($0.key) }
            .min { $0.key.count > $1.key.count || ($0.key.count == $1.key.count && $0.key < $1.key) }?.value
    }
}
