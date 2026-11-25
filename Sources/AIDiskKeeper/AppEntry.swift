import DiskKeeperCore
import Foundation

@main
enum AppEntry {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--verify-resources") {
            exit(ResourceSelfCheck.run())
        }
        AIDiskKeeperApp.main()
    }
}

enum ResourceSelfCheck {
    /// Prints exactly these lines to stdout, then returns 0 if the rules dir exists, else 1:
    ///   bundle=<absolute path or MISSING>
    ///   rules=<absolute path or MISSING>
    ///   ruleFiles=<count of *.json in rules dir>
    static func run() -> Int32 {
        let bundleURL = CoreResources.bundle?.bundleURL
        let rulesURL = CoreResources.rulesDirectoryURL
        var count = 0
        if let rulesURL,
           let names = try? FileManager.default.contentsOfDirectory(atPath: rulesURL.path) {
            count = names.filter { $0.hasSuffix(".json") }.count
        }
        print("bundle=\(bundleURL?.path ?? "MISSING")")
        print("rules=\(rulesURL?.path ?? "MISSING")")
        print("ruleFiles=\(count)")
        return rulesURL == nil ? 1 : 0
    }
}
