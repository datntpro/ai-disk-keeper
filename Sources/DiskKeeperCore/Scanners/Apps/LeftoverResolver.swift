import Foundation

struct LeftoverMatch: Sendable, Hashable {
    enum Level: String, Sendable { case exact, name, orphan }
    let entry: LibraryEntry
    let level: Level
    /// The single owning app (exact, or a name match to exactly one app). nil for orphans and shared entries.
    let owner: InstalledApp?
    /// Two or more installed apps that could own a name-level entry.
    let sharedWith: [InstalledApp]

    var ruleID: String { "apps.leftover.\(level.rawValue)" }
}

/// Pure matching of installed apps against a `LibraryIndex`. Conservative by design: bundle ids and exact
/// names only, never vendor-wide folders, never Apple items.
enum LeftoverResolver {
    static let orphanMinAgeDays = 30.0

    /// Folded names that are never a name-level match (vendor-wide or generic folders).
    static let stoplist: Set<String> = [
        "apple", "com", "library", "caches", "logs", "default", "shared", "electron", "chromium", "google",
        "microsoft", "adobe", "jetbrains", "temp", "tmp", "data", "cache", "crashpad", "sentry", "squirrel",
    ]

    static func resolve(apps: [InstalledApp], index: LibraryIndex, now: Date,
                        isInstalledAnywhere: (String) -> Bool?) -> [LeftoverMatch] {
        // Every installed id claims its entries (Apple ones too, so they are skipped, not orphaned).
        var byID: [String: InstalledApp] = [:]
        for a in apps where byID[PathCanonicalizer.fold(a.bundleID)] == nil { byID[PathCanonicalizer.fold(a.bundleID)] = a }
        let candidates = apps.filter { $0.source != .apple }
        let appleNames = Set(apps.filter { $0.source == .apple }.flatMap { [$0.name, $0.bundleName].compactMap { $0 } }
            .map(PathCanonicalizer.fold))

        var byName: [String: [InstalledApp]] = [:]
        for a in candidates {
            var seen = Set<String>()
            for n in [a.name, a.bundleName].compactMap({ $0 }) {
                let f = PathCanonicalizer.fold(n)
                guard f.count >= 3, !stoplist.contains(f), !appleNames.contains(f), seen.insert(f).inserted else { continue }
                byName[f, default: []].append(a)
            }
        }
        var byTeam: [String: [InstalledApp]] = [:]
        for a in candidates { if let t = a.source.teamID { byTeam[PathCanonicalizer.fold(t), default: []].append(a) } }

        // An id is only called an app's leftover if an app-only location mentions it too (a sandbox container or
        // saved window state). CLI tools and frameworks (org.swift.swiftpm, crash reporters) have neither.
        var evidence = Set<String>()
        for entry in index.entries where entry.location == .containers || entry.location == .savedState {
            if let id = orphanCandidate(entry, ids: Set(byID.keys)) { evidence.insert(PathCanonicalizer.fold(id)) }
        }

        var out: [LeftoverMatch] = []
        var seenPaths = Set<PathKey>()
        func emit(_ m: LeftoverMatch) {
            if seenPaths.insert(PathCanonicalizer.key(m.entry.path)).inserted { out.append(m) }
        }

        for entry in index.entries {
            let foldedName = PathCanonicalizer.fold(entry.name)
            if foldedName.hasPrefix("com.apple.") || foldedName.contains(".com.apple.") { continue }

            // 1. Exact: bundle-id derived.
            if let owner = exactOwner(of: entry, byID: byID, candidates: apps) {
                if owner.source != .apple { emit(LeftoverMatch(entry: entry, level: .exact, owner: owner, sharedWith: [])) }
                continue
            }

            // 2. Name level.
            if let m = nameMatch(entry, byName: byName, byTeam: byTeam) { emit(m); continue }

            // 3. Orphan (fail safe: every doubt means "not an orphan").
            if let id = orphanCandidate(entry, ids: Set(byID.keys)), evidence.contains(PathCanonicalizer.fold(id)),
               orphanIsOld(entry, now: now), !hasKnownNonAppOwner(id), hostMayBeInstalled(id, isInstalledAnywhere) == false {
                emit(LeftoverMatch(entry: entry, level: .orphan, owner: nil, sharedWith: []))
            }
        }
        return out
    }

    // MARK: Exact

    /// Candidate ids for an entry, longest first, and whether prefix-stripping is allowed.
    private static func idCandidates(_ entry: LibraryEntry) -> [String] {
        func stripped(_ suffix: String) -> String? {
            let n = entry.name
            guard n.count > suffix.count, PathCanonicalizer.fold(n).hasSuffix(suffix) else { return nil }
            return String(n.dropLast(suffix.count))
        }
        func dropLast(_ s: String) -> String? {
            guard let i = s.lastIndex(of: ".") else { return nil }
            return String(s[..<i])
        }
        switch entry.location {
        case .httpStorages:
            return [stripped(".binarycookies") ?? entry.name]
        case .applicationSupport, .caches, .containers, .webKit, .logs:
            return [entry.name]
        case .preferences, .preferencesByHost:
            guard let stem = stripped(".plist") else { return [] }
            return [stem] + (dropLast(stem).map { [$0] } ?? [])
        case .savedState:
            return stripped(".savedstate").map { [$0] } ?? []
        case .cookies:
            return stripped(".binarycookies").map { [$0] } ?? []
        case .groupContainers:
            guard let rest = groupContainerRemainder(entry.name) else { return [] }
            return [rest]
        case .launchAgents:
            var out: [String] = []
            for source in [entry.launchLabel, stripped(".plist")].compactMap({ $0 }) {
                var s = source
                out.append(s)
                while let shorter = dropLast(s) { out.append(shorter); s = shorter }
            }
            return out
        }
    }

    /// `TEAMID.rest` where TEAMID is 10 alphanumerics.
    static func groupContainerRemainder(_ name: String) -> String? {
        guard let (team, rest) = splitTeam(name) else { return nil }
        _ = team
        return rest
    }

    static func splitTeam(_ name: String) -> (String, String)? {
        guard let dot = name.firstIndex(of: ".") else { return nil }
        let team = String(name[..<dot])
        let rest = String(name[name.index(after: dot)...])
        guard team.count == 10, team.utf8.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) }),
              !rest.isEmpty else { return nil }
        return (team, rest)
    }

    private static func exactOwner(of entry: LibraryEntry, byID: [String: InstalledApp],
                                   candidates: [InstalledApp]) -> InstalledApp? {
        for c in idCandidates(entry) {
            guard let app = byID[PathCanonicalizer.fold(c)] else { continue }
            if entry.location == .groupContainers, let (team, _) = splitTeam(entry.name),
               let appTeam = app.source.teamID, PathCanonicalizer.fold(appTeam) != PathCanonicalizer.fold(team) { continue }
            return app
        }
        if entry.location == .launchAgents, let program = entry.launchProgram {
            let programKey = PathCanonicalizer.key(program).components
            for app in candidates {
                let appKey = PathCanonicalizer.key(app.path).components
                if programKey.count > appKey.count, Array(programKey.prefix(appKey.count)) == appKey { return app }
            }
        }
        return nil
    }

    // MARK: Name level

    private static func nameMatch(_ entry: LibraryEntry, byName: [String: [InstalledApp]],
                                  byTeam: [String: [InstalledApp]]) -> LeftoverMatch? {
        var apps: [InstalledApp] = []
        switch entry.location {
        case .applicationSupport, .caches, .logs:
            apps = byName[PathCanonicalizer.fold(entry.name)] ?? []
        case .groupContainers:
            if let (team, _) = splitTeam(entry.name) { apps = byTeam[PathCanonicalizer.fold(team)] ?? [] }
        default:
            return nil
        }
        var unique: [InstalledApp] = []
        for a in apps where !unique.contains(where: { $0.bundleID == a.bundleID }) { unique.append(a) }
        switch unique.count {
        case 0: return nil
        case 1: return LeftoverMatch(entry: entry, level: .name, owner: unique[0], sharedWith: [])
        default: return LeftoverMatch(entry: entry, level: .name, owner: nil, sharedWith: unique)
        }
    }

    // MARK: Orphans

    private static let orphanLocations: Set<LibraryLocation> = [
        .containers, .caches, .httpStorages, .webKit, .savedState, .preferences, .applicationSupport,
    ]

    /// The bundle id an orphan entry is named after, if it is a plausible orphan candidate.
    private static func orphanCandidate(_ entry: LibraryEntry, ids installed: Set<String>) -> String? {
        guard orphanLocations.contains(entry.location) else { return nil }
        let raw: String
        switch entry.location {
        case .preferences:
            guard entry.name.lowercased().hasSuffix(".plist") else { return nil }
            raw = String(entry.name.dropLast(6))
        case .savedState:
            guard entry.name.lowercased().hasSuffix(".savedstate") else { return nil }
            raw = String(entry.name.dropLast(11))
        case .httpStorages:
            raw = entry.name.lowercased().hasSuffix(".binarycookies") ? String(entry.name.dropLast(14)) : entry.name
        default:
            raw = entry.name
        }
        guard RuleCleanup.isValidBundleID(raw), raw.split(separator: ".").count >= 3 else { return nil }
        let folded = PathCanonicalizer.fold(raw)
        if folded.hasPrefix("com.apple.") { return nil }
        // Claimed by an installed app (it, or a namespace parent/child of it)?
        for id in installed where folded == id || folded.hasPrefix(id + ".") || id.hasPrefix(folded + ".") { return nil }
        return raw
    }

    /// Frameworks and developer tools whose ids look like app ids but are never "an app that was removed".
    static let nonAppPrefixes = [
        "org.swift.", "org.llvm.", "org.python.", "org.gnu.", "org.gradle.", "io.flutter.", "com.plausiblelabs.",
        "com.google.keystone", "com.microsoft.autoupdate", "com.github.", "sh.brew.", "com.jetbrains.",
    ]

    static func hasKnownNonAppOwner(_ id: String) -> Bool {
        let f = PathCanonicalizer.fold(id)
        return nonAppPrefixes.contains { f.hasPrefix($0) }
    }

    /// Asks LaunchServices (all install locations: /Applications, ~/Applications, Setapp, App Store, Homebrew
    /// casks, other volumes) about the id and each namespace parent with 3+ components, so an extension or
    /// helper container (`com.x.app.extension`) is not an orphan while its host (`com.x.app`) is installed.
    /// Returns false only when every answer is a definite "no"; true or unknown both mean "may be installed".
    static func hostMayBeInstalled(_ id: String, _ lookup: (String) -> Bool?) -> Bool {
        var parts = id.split(separator: ".").map(String.init)
        while parts.count >= 3 {
            if lookup(parts.joined(separator: ".")) != false { return true }
            parts.removeLast()
        }
        return false
    }

    private static func orphanIsOld(_ entry: LibraryEntry, now: Date) -> Bool {
        guard let m = entry.modified else { return false }
        return now.timeIntervalSince(m) > orphanMinAgeDays * 86_400
    }
}
