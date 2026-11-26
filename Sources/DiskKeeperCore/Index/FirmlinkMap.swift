import Foundation

/// The firmlinks of the data volume (`/usr/share/firmlinks`): `/Users` is really `/System/Volumes/Data/Users`.
/// Used only to show a friendly path for full-disk indexes; guard evaluation already folds the prefix.
struct FirmlinkMap: Sendable, Hashable {
    struct Link: Sendable, Hashable {
        let system: [String]   // components of the visible path, e.g. ["Users"]
        let data: [String]     // components below /System/Volumes/Data, e.g. ["Users"]
    }
    let links: [Link]

    static let empty = FirmlinkMap(links: [])

    /// Parses lines of `<visible path><TAB><data volume relative path>`. Comments and malformed lines are ignored.
    static func parse(_ text: String) -> FirmlinkMap {
        var out: [Link] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let fields = trimmed.split(whereSeparator: { $0 == "\t" || $0 == " " }).map(String.init)
            guard fields.count == 2, fields[0].hasPrefix("/"), !fields[1].hasPrefix("/") else { continue }
            let sys = PathNormalization.components(fields[0]).map(String.init)
            let data = PathNormalization.components("/" + fields[1]).map(String.init)
            guard !sys.isEmpty, !data.isEmpty, !sys.contains(".."), !data.contains("..") else { continue }
            out.append(Link(system: sys, data: data))
        }
        return FirmlinkMap(links: out)
    }

    static func load(path: String) -> FirmlinkMap {
        guard let data = FileManager.default.contents(atPath: path) else { return .empty }
        return parse(String(decoding: data, as: UTF8.self))
    }

    private static let dataPrefix = ["System", "Volumes", "Data"]

    /// `/System/Volumes/Data/Users/x` → `/Users/x` when `Users` is a firmlink; everything else unchanged.
    func displayPath(_ path: String) -> String {
        let comps = PathNormalization.components(path).map(String.init)
        guard comps.count > 3, Array(comps[0..<3]) == Self.dataPrefix else { return path }
        let rest = Array(comps[3...])
        var best: Link?
        for l in links where rest.count >= l.data.count && Array(rest[0..<l.data.count]) == l.data {
            if best == nil || l.data.count > best!.data.count { best = l }
        }
        guard let link = best else { return path }
        return "/" + (link.system + rest[link.data.count...]).joined(separator: "/")
    }
}
