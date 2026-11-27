import DiskKeeperCore
import Foundation

// Developer-only, read-only: runs the bundled (and optional extra) JSON rules against the REAL home and
// prints what they find. Usage: swift run adk-scan [--rules-dir DIR] [--tool ID] [--json] [--cache]

struct Options {
    var rulesDir: String?
    var tool: String?
    var json = false
    /// Use (and update) the same incremental size cache as the app, to time first vs second scans.
    var cache = false
}

func parseOptions() -> Options {
    var o = Options()
    var args = CommandLine.arguments.dropFirst()
    while let a = args.popFirst() {
        switch a {
        case "--rules-dir": o.rulesDir = args.popFirst()
        case "--tool": o.tool = args.popFirst()
        case "--json": o.json = true
        case "--cache": o.cache = true
        default:
            FileHandle.standardError.write(Data("usage: adk-scan [--rules-dir DIR] [--tool ID] [--json] [--cache]\n".utf8))
            exit(2)
        }
    }
    return o
}

func human(_ bytes: Int64) -> String {
    let units = ["B", "K", "M", "G", "T"]
    var v = Double(bytes)
    var i = 0
    while v >= 1024 && i < units.count - 1 { v /= 1024; i += 1 }
    return i == 0 ? "\(bytes)B" : String(format: v < 10 ? "%.1f%@" : "%.0f%@", v, units[i])
}

actor Collector {
    var items: [ScanItem] = []
    var warnings: [ScanWarning] = []
    func add(_ i: ScanItem) { items.append(i) }
    func add(_ w: ScanWarning) { warnings.append(w) }
}

func run() async throws {
    let options = parseOptions()
    let env = PathEnvironment.current()
    let loader = RuleLoader(
        environment: env,
        bundledRulesDirectory: options.rulesDir.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? CoreResources.rulesDirectoryURL,
        userRulesDirectory: nil,
        guardFactory: ScanGuard.loaderFactory(environment: env))
    let loaded = loader.load()
    for e in loaded.errors { FileHandle.standardError.write(Data("rule error: \(e)\n".utf8)) }
    for w in loaded.warnings { FileHandle.standardError.write(Data("rule warning: \(w)\n".utf8)) }
    var rules = loaded.allRules
    if let tool = options.tool { rules = rules.filter { $0.tool.rawValue == tool } }

    let pathGuard = try ScanGuard(environment: env, protectPatterns: loaded.protectPatterns)
    let sizeCache = options.cache ? SizeCache(fileURL: SizeCache.defaultFileURL(environment: env)) : nil
    let context = ScanContext(environment: env, pathGuard: pathGuard, sizeCache: sizeCache)
    let started = ContinuousClock.now
    await sizeCache?.beginScan(options: context.sizerOptions)
    let collector = Collector()
    let sink = ScanSink(item: { await collector.add($0) }, warning: { await collector.add($0) }, progress: { _ in })
    try await RuleScanner(rules: rules).scan(context: context, sink: sink)
    await sizeCache?.endScan()
    if let sizeCache {
        let hits = await sizeCache.hits, misses = await sizeCache.misses
        FileHandle.standardError.write(Data("scan took \(started.duration(to: .now)); cache hits \(hits), misses \(misses)\n".utf8))
    }

    let items = await collector.items.sorted { ($0.ruleID, $0.path) < ($1.ruleID, $1.path) }
    let warnings = await collector.warnings
    if options.json {
        let result = ScanResult(items: items, warnings: warnings, startedAt: context.now, finishedAt: Date())
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        print(String(decoding: try enc.encode(result), as: UTF8.self))
        return
    }
    for i in items {
        let path = i.path.hasPrefix(env.home) ? "~" + i.path.dropFirst(env.home.count) : i.path
        print("\(i.tier.rawValue.padding(toLength: 7, withPad: " ", startingAt: 0)) \(human(i.sizeAllocated).padding(toLength: 6, withPad: " ", startingAt: 0)) \(i.tool.rawValue) \(i.ruleID) \(path)")
    }
    print("\nTotals per rule:")
    for (rule, group) in Dictionary(grouping: items, by: \.ruleID).sorted(by: { $0.key < $1.key }) {
        print("  \(rule): \(group.count) items, \(human(group.reduce(0) { $0 + $1.sizeAllocated }))")
    }
    for w in warnings { print("warning [\(w.kind.rawValue)] \(w.path ?? "") \(w.message)") }
}

do { try await run() } catch {
    FileHandle.standardError.write(Data("adk-scan failed: \(error)\n".utf8))
    exit(1)
}
