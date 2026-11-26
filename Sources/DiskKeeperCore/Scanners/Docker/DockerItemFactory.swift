import Foundation

/// Builds the virtual `ScanItem`s for one runtime from the parsed `docker` listings. Pure.
struct DockerItemFactory {
    let target: String
    let runtimeName: String
    let suffixRuntime: Bool
    let now: Date

    static let maxItems = 500
    static let freshImage: TimeInterval = 3600

    struct Inputs {
        var df: DockerJSON.DF
        var images: [DockerJSON.ImageRow]
        var containers: [DockerJSON.ContainerRow]
        var volumes: [DockerJSON.VolumeRow]
    }

    func items(_ i: Inputs) -> [ScanItem] {
        var out = images(i) + containers(i) + volumes(i)
        out.sort { $0.sizeAllocated > $1.sizeAllocated }
        if out.count > Self.maxItems { out = Array(out.prefix(Self.maxItems)) }
        if let cache = buildCache(i.df) { out.append(cache) }
        return out
    }

    // MARK: Images

    private func images(_ i: Inputs) -> [ScanItem] {
        var byID: [String: [DockerJSON.ImageRow]] = [:]
        for r in i.images { byID[r.id, default: []].append(r) }
        var out: [ScanItem] = []
        for (fullID, rows) in byID {
            guard ArgPattern.dockerImageID.matches(fullID) else { continue }
            let short = DockerJSON.stripSHA(fullID)
            let matches = i.df.images.filter { !$0.id.isEmpty && short.hasPrefix($0.id) }
            // The df ID must name exactly one listed image, and no other df entry may be ambiguous with it.
            guard let df = matches.first, matches.allSatisfy({ $0.id == df.id }),
                  i.images.map(\.id).filter({ DockerJSON.stripSHA($0).hasPrefix(df.id) }).allSatisfy({ $0 == fullID }) else { continue }
            guard let used = df.containers, used == 0 else { continue }
            let tags = rows.filter { $0.repository != "<none>" && $0.tag != "<none>" }.map { "\($0.repository):\($0.tag)" }
            let named = Set(tags)
            // A container that names this image by tag or ID means it is in use even if df lagged behind.
            if i.containers.contains(where: { c in named.contains(c.image) || (!c.image.isEmpty && short.hasPrefix(c.image)) }) { continue }
            let created = rows.compactMap(\.created).min()
            let size = df.size ?? 0
            if tags.isEmpty {
                let old = created.map { now.timeIntervalSince($0) >= Self.freshImage } ?? false
                out.append(make(kind: "image", id: fullID, name: "Untagged image \(short.prefix(8))", size: size, date: created,
                                tier: old ? .safe : .review, rule: DockerToolCommands.Rule.dangling,
                                method: .toolCommand(command: "docker", arguments: ["image", "rm", fullID])))
            } else {
                let refs = Array(Set(tags)).sorted()
                guard refs.count <= 8, refs.allSatisfy({ ArgPattern.dockerImageRef.matches($0) }) else { continue }
                let name = refs.count > 1 ? "\(refs[0]) (+\(refs.count - 1) tags)" : refs[0]
                out.append(make(kind: "image", id: fullID, name: name, size: size, date: created, tier: .review,
                                rule: DockerToolCommands.Rule.unusedImage,
                                method: .toolCommand(command: "docker", arguments: ["image", "rm"] + refs)))
            }
        }
        return out
    }

    // MARK: Containers

    private func containers(_ i: Inputs) -> [ScanItem] {
        var out: [ScanItem] = []
        for c in i.containers where ["exited", "created", "dead"].contains(c.state) {
            guard ArgPattern.dockerContainerID.matches(c.id) else { continue }
            let matches = i.df.containers.filter { !$0.id.isEmpty && c.id.hasPrefix($0.id) }
            guard matches.count == 1, let df = matches.first else { continue }
            let name = suffixed(c.image.isEmpty ? c.name : "\(c.name) · \(c.image)")
            out.append(make(kind: "container", id: c.id, name: name, size: df.size ?? 0, date: c.created, tier: .review,
                            rule: DockerToolCommands.Rule.container,
                            method: .toolCommand(command: "docker", arguments: ["container", "rm", c.id]), plainName: true))
        }
        return out
    }

    // MARK: Volumes

    private func volumes(_ i: Inputs) -> [ScanItem] {
        var out: [ScanItem] = []
        for v in i.volumes {
            guard ArgPattern.dockerVolumeName.matches(v.name) else { continue }
            let dfs = i.df.volumes.filter { $0.name == v.name }
            guard dfs.count == 1, let df = dfs.first, df.links == 0 else { continue }
            let anonymous = v.name.utf8.count == 64 && ArgPattern.dockerContainerID.matches(v.name)
            let devcontainer = v.labels.lowercased().contains("devcontainer")
            let display = anonymous ? String(v.name.prefix(12)) : v.name
            if anonymous || devcontainer {
                out.append(make(kind: "volume", id: v.name, name: display, size: df.size ?? 0, date: nil, tier: .review,
                                rule: DockerToolCommands.Rule.anonymousVolume,
                                method: .toolCommand(command: "docker", arguments: ["volume", "rm", v.name])))
            } else {
                out.append(make(kind: "volume", id: v.name, name: display, size: df.size ?? 0, date: nil, tier: .keep,
                                rule: DockerToolCommands.Rule.namedVolume, method: .none))
            }
        }
        return out
    }

    // MARK: Build cache

    private func buildCache(_ df: DockerJSON.DF) -> ScanItem? {
        let unused = df.cache.filter { $0.inUse == false }
        let total = unused.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
        guard total > 0 else { return nil }
        return make(kind: "buildcache", id: "all", name: "Build cache", size: total, date: unused.compactMap(\.lastUsed).max(),
                    tier: .safe, rule: DockerToolCommands.Rule.buildCache,
                    method: .toolCommand(command: "docker", arguments: ["builder", "prune", "--all", "--force"]))
    }

    // MARK: Item

    static let explanations: [String: String] = [
        DockerToolCommands.Rule.dangling: "An untagged image left behind when a newer build replaced it. No container uses it. Docker removes it; nothing you need is lost.",
        DockerToolCommands.Rule.unusedImage: "An image no container uses. Docker downloads or builds it again the next time you need it.",
        DockerToolCommands.Rule.container: "A stopped container. Removing it deletes files changed inside it and its logs. Volumes it used are kept.",
        DockerToolCommands.Rule.anonymousVolume: "An unnamed volume no container uses. Volumes can hold databases; check before removing. This can't be undone.",
        DockerToolCommands.Rule.namedVolume: "A named volume no container uses right now. It may hold a database or project data, so AI Disk Keeper won't remove it. If you're sure, run `docker volume rm <name>` in Terminal.",
        DockerToolCommands.Rule.buildCache: "Build cache that no running build uses. Docker recreates it as needed; your next builds may be slower.",
    ]

    private func suffixed(_ s: String) -> String { suffixRuntime ? "\(s) · \(runtimeName)" : s }

    private func make(kind: String, id: String, name: String, size: Int64, date: Date?, tier: RiskTier, rule: String,
                      method: CleanupMethod, plainName: Bool = false) -> ScanItem {
        let path = VirtualItemPath.build(namespace: "docker", target: target, kind: kind, id: id)!
        return ScanItem(url: URL(fileURLWithPath: path), displayName: plainName ? name : suffixed(name), tool: .docker,
                        category: .docker, sizeAllocated: size, sizeLogical: size, fileCount: 0, lastModified: date,
                        tier: tier, explanation: Self.explanations[rule] ?? "", ruleID: rule, cleanupMethod: method,
                        groupID: "docker:\(target)")
    }
}
