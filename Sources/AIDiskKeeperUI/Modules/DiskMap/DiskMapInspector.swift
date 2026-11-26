import DiskKeeperCore
import Foundation
import SwiftUI

/// Pure snapshot of what the inspector shows for one node. No destructive action exists in `Action`.
struct InspectorInfo: Equatable {
    enum Action: CaseIterable, Equatable { case reviewInList, revealInFinder }

    enum Classification: Equatable {
        /// A scanner item sits exactly on this node.
        case exact(ScanItem.ID)
        /// The item is inside this node's package / small-items summary.
        case inside(ScanItem.ID)
        case unclassified
    }

    struct Largest: Equatable, Identifiable {
        let id: DiskNodeID
        let name: String
        let bytes: Int64
    }

    let id: DiskNodeID
    let name: String
    let path: String
    let revealPath: String
    let bytes: Int64
    /// Only when it differs from `bytes` by more than 10 %.
    let logicalBytes: Int64?
    let shareOfParent: Double?
    let shareOfFocus: Double?
    let focusName: String
    let fileCount: Int
    let newest: Date?
    let kind: DiskMapCopy.Kind
    let isProtected: Bool
    let needsFullDiskAccess: Bool
    let notes: [DiskMapCopy.Note]
    let largest: [Largest]
    let classification: Classification
    let tier: RiskTier?
    /// The layer colour key for the swatch.
    let layer: StrataLayer

    var actions: [Action] {
        switch classification {
        case .exact, .inside: [.reviewInList, .revealInFinder]
        case .unclassified: [.revealInFinder]
        }
    }

    var reviewItemID: ScanItem.ID? {
        switch classification {
        case .exact(let id), .inside(let id): id
        case .unclassified: nil
        }
    }
}

enum DiskMapInspector {
    static func info(tree: DiskTree, node id: DiskNodeID, focus: DiskNodeID, overlay: DiskMapOverlay?,
                     rootName: String) -> InspectorInfo {
        let node = tree.node(id)
        let focusNode = tree.node(focus)
        let parent = node.parent.map { tree.node($0) }
        let flags = node.flags
        let attribution = overlay?.attribution(id)

        let kind: DiskMapCopy.Kind = if flags.contains(.smallItems) { .smallItems }
        else if flags.contains(.otherVolume) { .otherVolume }
        else if flags.contains(.dataless) { .iCloud }
        else if flags.contains(.package) { .package }
        else if flags.contains(.directory) { .folder }
        else { .file }

        var notes: [DiskMapCopy.Note] = []
        if flags.contains(.dataless) { notes.append(.dataless) }
        if flags.contains(.hardlinkRepeat) { notes.append(.hardlink) }
        if flags.contains(.sparse) { notes.append(.sparse) }
        if flags.contains(.compressed) { notes.append(.compressed) }
        if flags.contains(.unreadable) { notes.append(.unreadable) }

        let classification: InspectorInfo.Classification
        if let a = attribution, let first = a.itemIDs.first {
            classification = a.isExact ? .exact(first) : .inside(first)
        } else {
            classification = .unclassified
        }

        // The most cautious tier wins when several items sit below this node.
        let tier: RiskTier? = [RiskTier.keep, .review, .safe].first { attribution?.tiers.contains($0) == true }

        let largest = tree.children(of: id).prefix(5).compactMap { child -> InspectorInfo.Largest? in
            let c = tree.node(child)
            guard c.allocatedBytes > 0 else { return nil }
            return .init(id: child, name: DiskMapLabels.title(of: child, tree: tree, rootName: rootName), bytes: c.allocatedBytes)
        }

        let logical: Int64? = {
            guard node.allocatedBytes > 0 || node.logicalBytes > 0 else { return nil }
            let diff = abs(Double(node.logicalBytes - node.allocatedBytes))
            return diff > 0.1 * Double(max(node.allocatedBytes, 1)) ? node.logicalBytes : nil
        }()

        let revealID: DiskNodeID = (flags.contains(.smallItems) ? node.parent : nil) ?? id

        return InspectorInfo(
            id: id, name: DiskMapLabels.title(of: id, tree: tree, rootName: rootName),
            path: tree.displayPath(of: id), revealPath: tree.path(of: revealID),
            bytes: node.allocatedBytes, logicalBytes: logical,
            shareOfParent: parent.flatMap { $0.allocatedBytes > 0 ? Double(node.allocatedBytes) / Double($0.allocatedBytes) : nil },
            shareOfFocus: focusNode.allocatedBytes > 0 ? Double(node.allocatedBytes) / Double(focusNode.allocatedBytes) : nil,
            focusName: DiskMapLabels.title(of: focus, tree: tree, rootName: rootName),
            fileCount: node.fileCount, newest: node.newestModification, kind: kind,
            isProtected: flags.contains(.protected) || flags.contains(.outsideCleanableRoots),
            needsFullDiskAccess: flags.contains(.needsFullDiskAccess), notes: notes, largest: Array(largest),
            classification: classification, tier: tier, layer: StrataLayer(category: attribution?.dominantCategory))
    }
}

/// The right-hand pane while Disk Map is selected. Reads only; "Review in list" navigates, it never selects.
struct DiskMapInspectorView: View {
    let model: DiskMapModel
    let reviewInList: (ScanItem.ID) -> Void

    var body: some View {
        ScrollView {
            if let info = model.inspector {
                VStack(alignment: .leading, spacing: ADKTheme.Spacing.md) {
                    header(info)
                    PathText(info.path)
                    sizeBlock(info)
                    facts(info)
                    ForEach(info.notes, id: \.self) { note in
                        Label(DiskMapCopy.note(note), systemImage: "info.circle")
                            .font(.callout).foregroundStyle(.adkText2)
                    }
                    if info.needsFullDiskAccess {
                        Label(DiskMapCopy.needsFDA, systemImage: "lock").font(.callout).foregroundStyle(.adkText2)
                    }
                    classification(info)
                    if !info.largest.isEmpty { largest(info) }
                    actions(info)
                }
                .padding(ADKTheme.Spacing.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(DiskMapCopy.noSelection).foregroundStyle(.adkText2)
                    .padding(ADKTheme.Spacing.lg).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(DiskMapCopy.inspectorTitle)
    }

    private func header(_ info: InspectorInfo) -> some View {
        HStack(spacing: ADKTheme.Spacing.sm) {
            RoundedRectangle(cornerRadius: ADKTheme.Radius.sm)
                .fill(info.isProtected ? .adkKeepSoft : info.layer.color)
                .frame(width: 28, height: 28)
                .overlay {
                    if info.isProtected { Image(systemName: "lock.fill").foregroundStyle(.adkKeepInk) }
                }
                .accessibilityHidden(true)
            Text(info.name).font(ADKTheme.Font.headline).textSelection(.enabled).lineLimit(2)
        }
    }

    private func sizeBlock(_ info: InspectorInfo) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            SizeText(info.bytes).font(.system(.title, design: .default).weight(.light))
            if let p = info.shareOfParent {
                Text(DiskMapCopy.ofParent(DiskMapCopy.percent(p))).font(.caption).foregroundStyle(.adkText2)
            }
            if let p = info.shareOfFocus, info.id != model.focusID {
                Text(DiskMapCopy.share(DiskMapCopy.percent(p), of: info.focusName)).font(.caption).foregroundStyle(.adkText2)
            }
            if let logical = info.logicalBytes {
                Text(DiskMapCopy.logicalSize(Formatting.bytes(logical))).font(.caption).foregroundStyle(.adkText2)
            }
        }
    }

    private func facts(_ info: InspectorInfo) -> some View {
        Grid(alignment: .leading, horizontalSpacing: ADKTheme.Spacing.md, verticalSpacing: 4) {
            GridRow { fact(DiskMapCopy.kindLabel, DiskMapCopy.kind(info.kind)) }
            if info.kind != .file {
                GridRow { fact(DiskMapCopy.files, Formatting.count(info.fileCount)) }
            }
            GridRow { fact(DiskMapCopy.modified, Formatting.relative(info.newest)) }
        }
    }

    @ViewBuilder private func fact(_ label: String, _ value: String) -> some View {
        Text(label).font(.caption).foregroundStyle(.adkText3).gridColumnAlignment(.leading)
        Text(value).font(.caption).monospacedDigit()
    }

    @ViewBuilder private func classification(_ info: InspectorInfo) -> some View {
        if info.isProtected {
            SectionCard {
                Label(DiskMapCopy.protectedNote, systemImage: "lock.shield").font(.callout)
            }
        } else {
            switch info.classification {
            case .exact, .inside:
                SectionCard {
                    VStack(alignment: .leading, spacing: ADKTheme.Spacing.xs) {
                        if let tier = info.tier { Text(DiskMapCopy.scannerItem(DiskMapCopy.tierName(tier))).font(.callout.weight(.semibold)) }
                        if case .inside = info.classification {
                            Text(DiskMapCopy.insideMatch).font(.caption).foregroundStyle(.adkText2)
                        }
                    }
                }
            case .unclassified:
                SectionCard {
                    VStack(alignment: .leading, spacing: ADKTheme.Spacing.xs) {
                        Text(DiskMapCopy.notClassifiedTitle).font(.caption.weight(.semibold)).foregroundStyle(.adkText3)
                        Text(DiskMapCopy.notClassifiedBody).font(.callout)
                    }
                }
            }
        }
    }

    private func largest(_ info: InspectorInfo) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(DiskMapCopy.largestInside).font(.subheadline.weight(.semibold))
            ForEach(info.largest) { row in
                Button { model.select(row.id) } label: {
                    HStack {
                        Text(row.name).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 8)
                        Text(Formatting.bytes(row.bytes)).monospacedDigit().foregroundStyle(.adkText2)
                    }
                    .font(.callout)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, 3)
            }
        }
    }

    private func actions(_ info: InspectorInfo) -> some View {
        VStack(alignment: .leading, spacing: ADKTheme.Spacing.sm) {
            ForEach(info.actions, id: \.self) { action in
                switch action {
                case .reviewInList:
                    Button(DiskMapCopy.reviewInList) { if let id = info.reviewItemID { reviewInList(id) } }
                        .buttonStyle(.borderedProminent)
                case .revealInFinder:
                    let url = URL(fileURLWithPath: info.revealPath)
                    Button { FinderReveal.reveal(url) } label: {
                        Label(DiskMapCopy.reveal, systemImage: "folder")
                    }
                    .disabled(!FinderReveal.exists(url))
                }
            }
        }
    }
}
