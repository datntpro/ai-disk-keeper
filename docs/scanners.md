# Writing a scanner

A *scanner* is a source of `ScanItem`s. Rule-driven scanning (JSON files, see `docs/rules.md`) is done by
`RuleScanner`, the production implementation and the best reference. Anything that needs code (git
worktrees, Docker, model stores) implements the `Scanner` protocol and is handed to `ScanEngine`.

## The contract

- **Read-only.** No writes, renames, lock files, caches, network, or `git` commands that take locks.
- **Report through the sink.** `sink.item`, `sink.warning` and `sink.progress` (absolute, not delta, progress of
  this scanner). A thrown error (other than cancellation) becomes one `.scannerFailed` warning; items already
  emitted are kept.
- **Let `CancellationError` propagate.** Never catch and drop it; check `Task.checkCancellation()` in loops.
- **Size with `context.size(_:)`.** It runs under one limiter shared by all scanners of a scan, so total sizing
  concurrency stays bounded. Do not start your own unbounded task groups for sizing.
- **Paths are lexical.** Join with `"/"`, never `URL.appendingPathComponent`, `standardizedFileURL` or
  `resolvingSymlinksInPath` (they strip `/private` or normalize Unicode). Do not follow symlinks.
- **Match with `matchesEither`** for every exclude or skip; use `matches` only to select.

## What the engine does with your items

Scanners need not coordinate with each other. For each item the engine:

1. re-checks `context.pathGuard.check(item.path)` and silently drops denied items (defense in depth);
2. rejects any item that equals, contains, or lies inside an already accepted item (alias- and case-folded).
   The **first item to arrive wins** across scanners; the loser produces one `.ruleError` warning;
3. then emits `.itemFound`. Events after the terminal `finished` or `cancelled` are never delivered.

The engine only drops items; it never changes a tier or any other field.

## Tiers

Start from the lowest-risk tier that is true for the item and only **escalate**, using
`RiskTier.escalated(to:)`. Never lower a tier. When unsure (incomplete size, unknown state), escalate to
`.review` or `.keep`.

## Example

The code below is `Tests/DiskKeeperCoreTests/Scan/ExampleScanner.swift`, verbatim (and tested by
`ScanEngineTests.testExampleScannerFromDocs`). Keep the two in sync.

```swift
/// Emits one `systemJunk` item per `*.log` file directly inside `directory`.
struct ExampleScanner: Scanner {
    let id = "example-logs"
    let directory: String

    func scan(context: ScanContext, sink: ScanSink) async throws {
        // A missing directory means "tool not installed": no items and no warning.
        guard FileManager.default.fileExists(atPath: directory) else { return }
        let names = try FileManager.default.contentsOfDirectory(atPath: directory).sorted()
        var found = 0
        for name in names where name.hasSuffix(".log") {
            try Task.checkCancellation()                      // let CancellationError propagate
            let path = directory + "/" + name                 // lexical join, never URL.appendingPathComponent
            guard context.pathGuard.check(path).isAllowed else { continue }
            let report = try await context.size(URL(fileURLWithPath: path))   // global sizing bound
            await sink.item(ScanItem(
                url: URL(fileURLWithPath: path), displayName: name, tool: "example",
                category: .systemJunk, sizeAllocated: report.allocatedBytes,
                sizeLogical: report.logicalBytes, fileCount: report.fileCount,
                lastModified: report.newestModification, tier: RiskTier.safe.escalated(to: report.isComplete ? .safe : .review),   // escalate only
                explanation: "Log file that can be regenerated.", ruleID: "example.logs"))
            found += 1
            await sink.progress(ScannerProgress(candidatesFound: found, candidatesSized: found))
        }
    }
}
```

Foundation also has a `Scanner` type, so a file that imports both should add `import protocol DiskKeeperCore.Scanner`.
