import DiskKeeperCore
import SwiftUI

/// One plan entry: tier badge, name, home-relative path, an annotation or the inline blocker, and the size.
struct CleanupPlanRow: View {
    let entry: CleanupPlanEntry
    /// Set on the first blocked row of a running app: shows the inline Re-check.
    var onRecheck: (() -> Void)?
    var home: String = NSHomeDirectory()

    static func displayPath(_ path: String, home: String) -> String {
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    private var blocked: Bool { !entry.isExecutable }

    private var firstBlockerSentence: String? {
        guard let b = entry.blockers.first else { return nil }
        if case .appRunning(let id) = b { return CleanupCopy.rowQuitFirst(app: AppNameResolver.name(forBundleID: id)) }
        return CleanupCopy.sentence(for: b)
    }

    /// Duplicate copies: the copy that stays (verified at plan time), plus how many more.
    private var keepingLine: String? {
        guard let kept = entry.survivors?.survivors, let first = kept.first else { return nil }
        let line = CleanupCopy.rowKeeping(Self.displayPath(first.path, home: home))
        return kept.count > 1 ? line + " " + CleanupCopy.rowOtherCopies(kept.count - 1) : line
    }

    private var annotation: String? {
        if let s = firstBlockerSentence { return s }
        var parts: [String] = []
        if case .trashWorktree = entry.item.cleanupMethod { parts.append(CleanupCopy.rowThenPrune) }
        if let keepingLine { parts.append(keepingLine) }
        if entry.isToolCommand { parts.append(CleanupCopy.rowByTool(entry.item.tool.uiName)) }
        if entry.item.tier == .review { parts.append(CleanupCopy.rowTickedByYou) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var moreHelp: String? {
        guard entry.blockers.count > 1 else { return nil }
        return entry.blockers.map { CleanupCopy.sentence(for: $0) }.joined(separator: "\n")
    }

    var body: some View {
        HStack(alignment: .top, spacing: ADKTheme.Spacing.md) {
            TierBadge(tier: entry.item.tier).frame(minWidth: 70, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.item.uiDisplayName()).lineLimit(1)
                if entry.isToolCommand, let line = entry.commandLine {
                    CommandText(line, help: entry.commandHelp)
                } else {
                    PathText(Self.displayPath(entry.item.url.path, home: home))
                }
                if let annotation {
                    HStack(spacing: 6) {
                        Text(annotation).font(.caption)
                            .foregroundStyle(blocked ? .adkReviewInk : .adkText3)
                        if blocked, entry.blockers.count > 1 {
                            Text(CleanupCopy.rowMoreReasons(entry.blockers.count - 1)).font(.caption).foregroundStyle(.adkText3)
                        }
                        if let onRecheck {
                            Button(CleanupCopy.recheck, action: onRecheck).buttonStyle(.plain).font(.caption.weight(.semibold)).foregroundStyle(.adkAccent)
                        }
                    }
                }
            }
            .help(moreHelp ?? "")
            Spacer(minLength: 8)
            SizeText(entry.item.sizeAllocated)
                .strikethrough(blocked)
                .foregroundStyle(blocked ? .adkText3 : .adkText)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(CleanupCopy.rowA11y(tier: TierStyle.style(for: entry.item.tier).label, name: entry.item.uiDisplayName(),
                                                reason: annotation ?? entry.item.explanation,
                                                size: SizeText.string(entry.item.sizeAllocated, .exact)))
    }
}
