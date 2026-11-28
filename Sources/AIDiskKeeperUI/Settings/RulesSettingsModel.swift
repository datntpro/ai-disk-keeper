import AppKit
import DiskKeeperCore
import Foundation
import Observation

/// One rule file shown in Settings → Rules.
struct RuleFileRow: Identifiable, Equatable {
    struct Rule: Identifiable, Equatable { let id: String; let title: String }
    var id: String { file.path }
    let file: URL
    let source: RuleSource
    let toolName: String
    let rules: [Rule]
}

/// An error or warning from a rule file, ready to show inline (file, JSON path, message).
struct RuleProblemRow: Identifiable, Equatable {
    let id: Int
    let file: String
    let jsonPath: String
    let message: String
    let isWarning: Bool
}

/// Loads rule files for the Rules tab. Loading and validating never scan anything and never write.
@MainActor @Observable
final class RulesSettingsModel {
    typealias Loader = @Sendable (_ userOnly: Bool) -> RuleLoadResult

    private(set) var files: [RuleFileRow] = []
    private(set) var problems: [RuleProblemRow] = []
    /// Set by "Validate": the user folder alone was checked.
    private(set) var validationSummary: String?
    private(set) var isLoading = false
    private(set) var folderError: String?

    @ObservationIgnored private let loader: Loader
    @ObservationIgnored private let environment: PathEnvironment
    @ObservationIgnored private let openFolder: @MainActor (URL) -> Void

    init(environment: PathEnvironment, loader: @escaping Loader, openFolder: @escaping @MainActor (URL) -> Void) {
        self.environment = environment
        self.loader = loader
        self.openFolder = openFolder
    }

    static func live(environment env: PathEnvironment) -> RulesSettingsModel {
        RulesSettingsModel(
            environment: env,
            loader: { userOnly in
                RuleLoader(environment: env,
                           bundledRulesDirectory: userOnly ? nil : CoreResources.rulesDirectoryURL,
                           userRulesDirectory: UserRulesDirectory.defaultURL(environment: env),
                           guardFactory: ScanGuard.loaderFactory(environment: env)).load()
            },
            openFolder: { NSWorkspace.shared.open($0) })
    }

    /// Re-runs the loader (bundled + user). Called off the main actor for the disk work.
    func reload() async {
        isLoading = true
        let loader = self.loader
        let result = await Task.detached { loader(false) }.value
        apply(result)
        validationSummary = nil
        isLoading = false
    }

    /// Runs the loader on the user folder alone and reports inline. No scan.
    func validate() async {
        isLoading = true
        let loader = self.loader
        let result = await Task.detached { loader(true) }.value
        apply(result)
        let count = result.errors.count
        validationSummary = count == 0
            ? loc("settings.rules.validate.ok", "No problems found in your rule files.")
            : loc("settings.rules.validate.problems", "\(String(count)) problem(s) found.")
        isLoading = false
    }

    /// Creates the folder (only here, on the user's action) and shows it in Finder.
    func openRulesFolder() {
        do {
            let url = try UserRulesDirectory.ensureExists(environment: environment)
            folderError = nil
            openFolder(url)
        } catch {
            folderError = loc("settings.rules.folderError", "Couldn't create the rules folder: \(error.localizedDescription)")
        }
    }

    func apply(_ result: RuleLoadResult) {
        files = result.ruleSets.map { set in
            RuleFileRow(file: set.file, source: set.source, toolName: set.tool.name,
                        rules: set.rules.map { .init(id: $0.rule.id, title: $0.rule.title) })
        }
        var rows: [RuleProblemRow] = []
        for e in result.errors { rows.append(Self.row(e, id: rows.count, warning: false)) }
        for w in result.warnings where w.source == .user { rows.append(Self.row(w, id: rows.count, warning: true)) }
        problems = rows
    }

    private static func row(_ e: RuleLoadError, id: Int, warning: Bool) -> RuleProblemRow {
        RuleProblemRow(id: id, file: e.file?.lastPathComponent ?? "", jsonPath: e.jsonPath, message: e.message, isWarning: warning)
    }
}
