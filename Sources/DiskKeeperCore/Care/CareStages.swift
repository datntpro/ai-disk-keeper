import Darwin
import Foundation

/// Ready-made stage builders. Each stage is read-only; nothing here can clean anything up.
///
/// `startup` has no builder: compose it with `scannerRun(.startup, modules: [.startup]) { … }` around the
/// startup scanner, so this file does not depend on it.
public enum CareStages {
    /// Runs the `ScanEngine` that `make` returns and forwards its events (raw event, items, warnings, progress).
    public static func scannerRun(_ stage: CareStage, modules: [CareModule],
                                  make: @escaping @Sendable () throws -> ScanEngine) -> CareStageSpec {
        CareStageSpec(stage: stage, modules: modules) { _, sink in
            try await forward(try make(), to: sink)
        }
    }

    /// One `ScanEngine` for AI tools, worktrees, models/Docker and system junk, so `PathClaimSet` dedupe stays intact.
    public static func rules(make: @escaping @Sendable () throws -> ScanEngine) -> CareStageSpec {
        scannerRun(.rules, modules: [.aiTools, .worktrees, .modelsDocker, .systemJunk], make: make)
    }

    /// Builds the disk index and hands it on (`.artifact(.tree)`) to the stages that need it.
    public static func index(_ build: @escaping @Sendable () async throws -> DiskTree) -> CareStageSpec {
        CareStageSpec(stage: .index, modules: []) { _, sink in
            await sink.progress(nil)
            let tree = try await build()
            try Task.checkCancellation()
            await sink.artifact(.tree(tree))
        }
    }

    public static func largeOld(_ scanner: LargeFileScanner, context: ScanContext) -> CareStageSpec {
        CareStageSpec(stage: .largeOld, modules: [.largeOld], needsTree: true) { input, sink in
            guard let tree = input.tree else { throw CancellationError() }
            await sink.progress(nil)
            let report = try await scanner.report(tree: tree, context: context)
            for w in report.warnings { await sink.warning(w) }
            for file in report.files {
                try Task.checkCancellation()
                await sink.item(LargeFileScanner.makeItem(file))
            }
            await sink.artifact(.largeFiles(report))
        }
    }

    public static func duplicates(options: DuplicateOptions, keeper: KeeperRule,
                                  guardProvider: @escaping @Sendable () throws -> ScanGuard,
                                  userID: uid_t) -> CareStageSpec {
        CareStageSpec(stage: .duplicates, modules: [.duplicates], needsTree: true) { input, sink in
            guard let tree = input.tree else { throw CancellationError() }
            let pathGuard = try guardProvider()
            await sink.progress(nil)
            let report = try await DuplicateFinder(options: options).find(in: tree)
            try Task.checkCancellation()
            for w in report.warnings { await sink.warning(w) }
            let byGroup = DuplicateScanner.items(for: report, rule: keeper, pathGuard: pathGuard, userID: userID)
            for group in report.groups {
                for item in byGroup[group.id] ?? [] {
                    try Task.checkCancellation()
                    await sink.item(item)
                }
            }
            await sink.artifact(.duplicates(report))
        }
    }

    /// App bundles go out directly (the scan guard drops `/Applications`; the uninstall flow has its own guard
    /// exception). Only bundles that can be uninstalled are listed; view-only ones (Apple, system) have nothing to
    /// reclaim. The leftovers run in their own engine.
    public static func apps(inventory: @escaping @Sendable () async throws -> AppInventory,
                            leftovers: @escaping @Sendable (AppInventory) throws -> ScanEngine) -> CareStageSpec {
        CareStageSpec(stage: .apps, modules: [.apps]) { _, sink in
            await sink.progress(nil)
            let found = try await inventory()
            try Task.checkCancellation()
            for w in found.warnings { await sink.warning(w) }
            await sink.artifact(.apps(found))
            for app in found.apps where app.viewOnlyReason == nil {
                await sink.item(app.makeScanItem())
            }
            try await forward(try leftovers(found), to: sink)
        }
    }

    // MARK: Engine plumbing

    private static func forward(_ engine: ScanEngine, to sink: CareStageSink) async throws {
        // With adjusters the final tiers are only known at the end: the tally must see the adjusted items.
        let deferItems = engine.adjustsItems
        let stream = try await engine.scan()
        await withTaskCancellationHandler {
            for await event in stream {
                await sink.scanEvent(event)
                switch event {
                case .itemFound(let item): if !deferItems { await sink.item(item) }
                case .warning(let w): await sink.warning(w)
                case .progress(let p):
                    await sink.progress(p.scannersTotal > 0 ? Double(p.scannersFinished) / Double(p.scannersTotal) : nil)
                case .finished(let r), .cancelled(let r):
                    if deferItems { for item in r.items { await sink.item(item) } }
                case .started, .itemsAdjusted: break
                }
            }
        } onCancel: {
            Task { await engine.cancel() }
        }
        try Task.checkCancellation()
    }
}
