import Foundation
@testable import DiskKeeperCore
import protocol DiskKeeperCore.Scanner

// EXAMPLE-BEGIN
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
// EXAMPLE-END
