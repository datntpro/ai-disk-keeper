import DiskKeeperCore
import SwiftUI

struct WarningsView: View {
    let warnings: [ScanWarning]

    var body: some View {
        List {
            ForEach(ScanWarning.Kind.allCases, id: \.self) { kind in
                let group = warnings.filter { $0.kind == kind }
                if !group.isEmpty {
                    Section(loc("warnings.section", "\(title(kind)) (\(group.count))")) {
                        if kind == .permissionDenied || kind == .needsFullDiskAccess {
                            Text(loc("warnings.fdaHint", "Grant Full Disk Access to include these (see Settings)."))
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        ForEach(Array(group.enumerated()), id: \.offset) { _, w in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(w.message)
                                if let p = w.path {
                                    Text(p).font(.caption.monospaced()).foregroundStyle(.secondary)
                                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func title(_ k: ScanWarning.Kind) -> String {
        switch k {
        case .permissionDenied: loc("warnings.kind.permissionDenied", "Permission denied")
        case .needsFullDiskAccess: loc("warnings.kind.needsFDA", "Needs Full Disk Access")
        case .notFound: loc("warnings.kind.notFound", "Not found")
        case .ruleError: loc("warnings.kind.ruleError", "Rule problems")
        case .scannerFailed: loc("warnings.kind.scannerFailed", "Scanner failed")
        case .timeout: loc("warnings.kind.timeout", "Timed out")
        case .other: loc("warnings.kind.other", "Other")
        }
    }
}
