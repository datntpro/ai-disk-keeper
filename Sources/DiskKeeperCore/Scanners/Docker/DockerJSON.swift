import Foundation

/// Lenient, pure parsing of `docker … --format '{{json .}}'` output: unknown keys are ignored and one bad record
/// skips only that record.
enum DockerJSON {
    struct DFImage { let id: String; let containers: Int?; let size: Int64? }
    struct DFContainer { let id: String; let size: Int64? }
    struct DFVolume { let name: String; let links: Int?; let size: Int64? }
    struct DFCache { let inUse: Bool?; let size: Int64?; let lastUsed: Date? }
    struct DF {
        var images: [DFImage] = [], containers: [DFContainer] = [], volumes: [DFVolume] = [], cache: [DFCache] = []
    }
    struct ImageRow { let id: String; let repository: String; let tag: String; let created: Date? }
    struct ContainerRow { let id: String; let name: String; let image: String; let state: String; let created: Date? }
    struct VolumeRow { let name: String; let labels: String }

    private typealias Record = [String: Any]

    static func serverVersion(_ data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? Record,
              let server = obj["Server"] as? Record else { return nil }
        return string(server["Version"])
    }

    /// `system df -v --format '{{json .}}'`: one object with `Images`, `Containers`, `Volumes`, `BuildCache`.
    /// nil = malformed.
    static func parseDF(_ data: Data) -> DF? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? Record else { return nil }
        var df = DF()
        for r in records(obj["Images"]) {
            guard let id = string(r["ID"]) else { continue }
            let unique = string(r["UniqueSize"]).flatMap(DockerSize.parse)
            df.images.append(DFImage(id: stripSHA(id), containers: int(r["Containers"]),
                                     size: unique ?? string(r["Size"]).flatMap(DockerSize.parse)))
        }
        for r in records(obj["Containers"]) {
            guard let id = string(r["ID"]) else { continue }
            df.containers.append(DFContainer(id: id, size: string(r["Size"]).flatMap(DockerSize.parse)))
        }
        for r in records(obj["Volumes"]) {
            guard let name = string(r["Name"]) else { continue }
            df.volumes.append(DFVolume(name: name, links: int(r["Links"]), size: string(r["Size"]).flatMap(DockerSize.parse)))
        }
        for r in records(obj["BuildCache"]) {
            df.cache.append(DFCache(inUse: bool(r["InUse"]), size: string(r["Size"]).flatMap(DockerSize.parse),
                                    lastUsed: string(r["LastUsedAt"]).flatMap(parseDate) ?? string(r["CreatedAt"]).flatMap(parseDate)))
        }
        return df
    }

    static func parseImages(_ data: Data) -> [ImageRow]? {
        lines(data)?.compactMap { r in
            guard let id = string(r["ID"]), id.hasPrefix("sha256:") else { return nil }
            return ImageRow(id: id, repository: string(r["Repository"]) ?? "<none>", tag: string(r["Tag"]) ?? "<none>",
                            created: string(r["CreatedAt"]).flatMap(parseDate))
        }
    }

    static func parseContainers(_ data: Data) -> [ContainerRow]? {
        lines(data)?.compactMap { r in
            guard let id = string(r["ID"]) else { return nil }
            let status = string(r["Status"]) ?? ""
            let state = (string(r["State"]) ?? status.split(separator: " ").first.map(String.init) ?? "").lowercased()
            let name = (string(r["Names"]) ?? "").split(separator: ",").first.map(String.init) ?? String(id.prefix(12))
            return ContainerRow(id: id, name: name, image: string(r["Image"]) ?? "", state: state,
                                created: string(r["CreatedAt"]).flatMap(parseDate))
        }
    }

    static func parseVolumes(_ data: Data) -> [VolumeRow]? {
        lines(data)?.compactMap { r in
            guard let name = string(r["Name"]) else { return nil }
            return VolumeRow(name: name, labels: string(r["Labels"]) ?? "")
        }
    }

    // MARK: Helpers

    /// JSON Lines. A line that doesn't parse is skipped; nil only when no line at all parsed but there was text.
    private static func lines(_ data: Data) -> [Record]? {
        let text = String(decoding: data, as: UTF8.self)
        var out: [Record] = []
        var sawLine = false
        for line in text.split(whereSeparator: \.isNewline) where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            sawLine = true
            if let r = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? Record { out.append(r) }
        }
        return (sawLine && out.isEmpty) ? nil : out
    }

    private static func records(_ any: Any?) -> [Record] { (any as? [Any])?.compactMap { $0 as? Record } ?? [] }

    private static func string(_ any: Any?) -> String? {
        switch any {
        case let s as String: return s
        case let n as NSNumber: return n.stringValue
        default: return nil
        }
    }

    private static func int(_ any: Any?) -> Int? {
        switch any {
        case let n as NSNumber: return n.intValue
        case let s as String: return Int(s.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    private static func bool(_ any: Any?) -> Bool? {
        switch any {
        case let b as Bool: return b
        case let s as String: return s.lowercased() == "true" ? true : (s.lowercased() == "false" ? false : nil)
        default: return nil
        }
    }

    static func stripSHA(_ id: String) -> String { id.hasPrefix("sha256:") ? String(id.dropFirst(7)) : id }

    /// `2024-05-01 10:00:00 +0000 UTC`, with optional fractional seconds; or ISO 8601.
    static func parseDate(_ text: String) -> Date? {
        let parts = text.split(separator: " ")
        if parts.count >= 3 {
            var time = String(parts[1])
            if let dot = time.firstIndex(of: ".") { time = String(time[..<dot]) }
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
            if let d = f.date(from: "\(parts[0]) \(time) \(parts[2])") { return d }
        }
        return ISO8601DateFormatter().date(from: text)
    }
}
