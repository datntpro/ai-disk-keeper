import Foundation

/// One pull request as `gh pr list --json` reports it.
public struct PRRecord: Sendable, Hashable {
    public var number: Int
    /// "MERGED", "CLOSED" or "OPEN".
    public var state: String
    public var headRefName: String
    public var headRefOid: String?
    public var mergedAt: Date?
    public var closedAt: Date?
    public var url: String?
    public init(number: Int, state: String, headRefName: String, headRefOid: String? = nil, mergedAt: Date? = nil,
                closedAt: Date? = nil, url: String? = nil) {
        self.number = number
        self.state = state
        self.headRefName = headRefName
        self.headRefOid = headRefOid
        self.mergedAt = mergedAt
        self.closedAt = closedAt
        self.url = url
    }
}

public enum PRLookup: Sendable, Hashable {
    case records([PRRecord])
    case unavailable(String)
}

/// Where pull request state comes from. The only implementation that touches the network is `GHCLIPRStatusSource`,
/// and only when the user turned the setting on.
public protocol PRStatusSource: Sendable {
    /// `remoteURL` is the repository's `origin` URL.
    func lookup(repository: String, remoteURL: String?) async -> PRLookup
}

public struct DisabledPRStatusSource: PRStatusSource {
    public init() {}
    public func lookup(repository: String, remoteURL: String?) async -> PRLookup { .unavailable("disabled") }
}

public enum PRMatcher {
    /// Matches by head branch name. An open PR wins, then the newest merged one, then the newest closed one.
    public static func state(branch: String?, records: [PRRecord]) -> PRState {
        guard let branch, !branch.isEmpty else { return .none }
        let mine = records.filter { $0.headRefName == branch }
        if let open = mine.filter({ $0.state.uppercased() == "OPEN" }).max(by: { $0.number < $1.number }) {
            return .open(number: open.number, url: open.url)
        }
        let merged = mine.filter { $0.state.uppercased() == "MERGED" }
            .max { ($0.mergedAt ?? .distantPast, $0.number) < ($1.mergedAt ?? .distantPast, $1.number) }
        if let merged {
            guard let oid = merged.headRefOid, !oid.isEmpty else { return .unknown(reason: "merged PR has no head commit") }
            return .merged(number: merged.number, headOID: oid, url: merged.url)
        }
        if let closed = mine.filter({ $0.state.uppercased() == "CLOSED" })
            .max(by: { ($0.closedAt ?? .distantPast, $0.number) < ($1.closedAt ?? .distantPast, $1.number) }) {
            return .closed(number: closed.number, url: closed.url)
        }
        return .none
    }

    /// `owner/name` for a github.com remote (https, ssh or scp-style); nil for any other host.
    public static func githubRepository(fromRemote url: String?) -> String? {
        guard var s = url?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        for prefix in ["https://", "http://", "ssh://", "git://"] where s.hasPrefix(prefix) {
            s = String(s.dropFirst(prefix.count))
            if let at = s.firstIndex(of: "@"), at < (s.firstIndex(of: "/") ?? s.endIndex) { s = String(s[s.index(after: at)...]) }
            guard s.hasPrefix("github.com/") || s.hasPrefix("github.com:") else { return nil }
            return ownerName(String(s.dropFirst("github.com/".count)))
        }
        if s.hasPrefix("git@github.com:") { return ownerName(String(s.dropFirst("git@github.com:".count))) }
        return nil
    }

    private static func ownerName(_ path: String) -> String? {
        var p = path
        if p.hasSuffix(".git") { p.removeLast(4) }
        while p.hasSuffix("/") { p.removeLast() }
        let parts = p.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber || "-_.".contains($0) } })
        else { return nil }
        return p
    }
}

/// `gh pr list --state all` for one repository, cached in memory for ten minutes. Only `pr list` is ever run.
public actor GHCLIPRStatusSource: PRStatusSource {
    public static let defaultCandidates = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"]

    private let home: String
    private let candidates: [String]
    private let runner: ProcessRunner
    private let timeout: Duration
    private let cacheLifetime: TimeInterval
    private let now: @Sendable () -> Date
    private var cache: [String: (at: Date, lookup: PRLookup)] = [:]

    public init(home: String, candidates: [String] = GHCLIPRStatusSource.defaultCandidates, runner: ProcessRunner = ProcessRunner(),
                timeout: Duration = .seconds(15), cacheLifetime: TimeInterval = 600, now: @escaping @Sendable () -> Date = { Date() }) {
        self.home = home
        self.candidates = candidates
        self.runner = runner
        self.timeout = timeout
        self.cacheLifetime = cacheLifetime
        self.now = now
    }

    public func lookup(repository: String, remoteURL: String?) async -> PRLookup {
        guard let slug = PRMatcher.githubRepository(fromRemote: remoteURL) else { return .unavailable("origin is not a GitHub repository") }
        if let hit = cache[slug], now().timeIntervalSince(hit.at) < cacheLifetime { return hit.lookup }
        guard let gh = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return .unavailable("GitHub CLI (gh) is not installed")
        }
        let result: PRLookup
        do {
            let r = try await runner.run(
                executable: URL(fileURLWithPath: gh),
                arguments: ["pr", "list", "--repo", slug, "--state", "all", "--limit", "300",
                            "--json", "number,state,headRefName,headRefOid,mergedAt,closedAt,url"],
                environment: ["HOME": home, "PATH": "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin", "GH_PROMPT_DISABLED": "1",
                              "NO_COLOR": "1", "LC_ALL": "C"],
                currentDirectory: URL(fileURLWithPath: "/"), timeout: timeout)
            if r.exitStatus != 0 {
                result = .unavailable("gh exited with status \(r.exitStatus)")
            } else if let records = Self.parse(r.stdout) {
                result = .records(records)
            } else {
                result = .unavailable("gh output could not be read")
            }
        } catch is CancellationError {
            return .unavailable("cancelled")
        } catch {
            result = .unavailable("gh could not run")
        }
        if case .records = result { cache[slug] = (now(), result) }
        return result
    }

    nonisolated static func parse(_ data: Data) -> [PRRecord]? {
        guard let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return nil }
        let iso = ISO8601DateFormatter()
        func date(_ v: Any?) -> Date? { (v as? String).flatMap { iso.date(from: $0) } }
        return arr.compactMap { o in
            guard let n = o["number"] as? Int, let state = o["state"] as? String, let head = o["headRefName"] as? String else { return nil }
            return PRRecord(number: n, state: state, headRefName: head, headRefOid: o["headRefOid"] as? String,
                            mergedAt: date(o["mergedAt"]), closedAt: date(o["closedAt"]), url: o["url"] as? String)
        }
    }
}
