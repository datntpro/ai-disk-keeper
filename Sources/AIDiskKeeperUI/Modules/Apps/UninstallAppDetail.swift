import AppKit
import DiskKeeperCore
import SwiftUI

/// The right side: one app, what it keeps in your Library, and the action bar.
struct UninstallAppDetail: View {
    let app: InstalledApp
    @Bindable var model: UninstallerModel
    let coordinator: CleanupCoordinator

    private var availability: UninstallAvailability { model.canUninstall(app) }
    private var group: UninstallGroup { model.group(for: app) }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: ADKTheme.Spacing.lg) {
                    header
                    if let g = model.guidance(for: app) { UninstallGuidanceCard(guidance: g, app: app, model: model) }
                    bundleSection
                    relatedSection
                    if !group.shared.isEmpty { sharedSection }
                    noteCard
                }
                .padding(ADKTheme.Spacing.lg)
            }
            actionBar
        }
    }

    private var sourceText: String {
        switch app.source {
        case .apple: UninstallerCopy.sourceApple
        case .appStore: UninstallerCopy.sourceAppStore
        case .developerID(let team): UninstallerCopy.sourceDeveloperID(team)
        case .unsigned, .unknown: UninstallerCopy.sourceUnsigned
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: ADKTheme.Spacing.md) {
            Image(nsImage: AppIconCache.icon(for: app.path)).resizable().frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name).font(ADKTheme.Font.title)
                PathText(UninstallLibrary.tilde(app.path, home: model.home))
                Text(verbatim: "\(app.bundleID) · \(sourceText)").font(.caption).foregroundStyle(.adkText3).textSelection(.enabled)
                Text(UninstallerCopy.total(Formatting.bytes(app.sizeAllocated), Formatting.count(group.related.count + group.shared.count)))
                    .font(.caption).foregroundStyle(.adkText2)
            }
            Spacer()
        }
    }

    private var bundleSection: some View {
        VStack(alignment: .leading, spacing: ADKTheme.Spacing.sm) {
            Text(UninstallerCopy.sectionBundle).font(.headline)
            SectionCard(padding: ADKTheme.Spacing.md) {
                HStack {
                    Image(systemName: "app.dashed").foregroundStyle(.adkText2)
                    Text(verbatim: (app.path as NSString).lastPathComponent).font(.callout)
                    Spacer()
                    Text(UninstallerCopy.matchExact).font(.caption.weight(.medium)).foregroundStyle(.adkSafeInk)
                        .padding(.horizontal, 8).padding(.vertical, 2).background(.adkSafeSoft, in: Capsule())
                    SizeText(app.sizeAllocated).font(.callout).foregroundStyle(.adkText2)
                }
            }
        }
    }

    private var relatedSection: some View {
        VStack(alignment: .leading, spacing: ADKTheme.Spacing.sm) {
            Text(UninstallerCopy.sectionRelated).font(.headline)
            if group.related.isEmpty {
                Text(UninstallerCopy.noRelated).font(.callout).foregroundStyle(.adkText3)
            } else {
                SectionCard(padding: ADKTheme.Spacing.md) {
                    VStack(spacing: 0) {
                        ForEach(group.related, id: \.id) { item in
                            UninstallRelatedRow(item: item, kind: UninstallRelatedKind(item), home: model.home,
                                                isOn: model.selection.isTicked(item)) { model.toggle(item) }
                            if item.id != group.related.last?.id { Divider() }
                        }
                    }
                }
            }
        }
    }

    private var sharedSection: some View {
        VStack(alignment: .leading, spacing: ADKTheme.Spacing.sm) {
            Text(UninstallerCopy.sectionShared).font(.headline)
            SectionCard(padding: ADKTheme.Spacing.md) {
                VStack(spacing: 0) {
                    ForEach(group.shared, id: \.id) { item in
                        UninstallRelatedRow(item: item, kind: .shared, owners: model.owners(of: item).map(\.name).sorted().joined(separator: ", "),
                                            home: model.home, isOn: model.selection.isTicked(item)) { model.toggle(item) }
                        if item.id != group.shared.last?.id { Divider() }
                    }
                }
            }
        }
    }

    private var noteCard: some View {
        SectionCard(padding: ADKTheme.Spacing.md) {
            VStack(alignment: .leading, spacing: 4) {
                Label(UninstallerCopy.noteTitle, systemImage: "info.circle").font(.callout.weight(.medium))
                Text(UninstallerCopy.noteBody(app.name)).font(.callout).foregroundStyle(.adkText2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var uninstallHelp: String {
        switch availability {
        case .available: ""
        case .running: UninstallerCopy.disabledRunning
        case .viewOnly(let reason): UninstallerCopy.locked(reason)
        }
    }

    private var actionBar: some View {
        HStack(spacing: ADKTheme.Spacing.md) {
            SizeText(model.tickedBytes, qualifier: .upTo).font(.headline)
            Text(UninstallerCopy.barSummary(Formatting.count(model.tickedRelated.count))).foregroundStyle(.adkText2)
            Spacer()
            Button(UninstallerCopy.reset) { model.resetApp(using: coordinator) }
                .disabled(!model.canReset).help(UninstallerCopy.resetHelp)
            Button(UninstallerCopy.uninstall) { model.uninstall(using: coordinator) }
                .buttonStyle(.borderedProminent).tint(.adkAccent)
                .disabled(availability != .available).help(uninstallHelp)
        }
        .font(.callout)
        .padding(.horizontal, ADKTheme.Spacing.lg).padding(.vertical, ADKTheme.Spacing.md)
        .background(.bar)
        .overlay(alignment: .top) { Rectangle().fill(.adkLine).frame(height: ADKTheme.hairline) }
    }
}

/// A guidance card: what stops the uninstall (or what macOS wants), and the one thing to do about it.
struct UninstallGuidanceCard: View {
    let guidance: UninstallGuidance
    let app: InstalledApp
    var model: UninstallerModel

    static func text(_ g: UninstallGuidance) -> String {
        switch g {
        case .appManagement: UninstallerCopy.guideAppManagement
        case .requiresAdmin: UninstallerCopy.guideAdmin
        case .running(let name): UninstallerCopy.guideRunning(name)
        case .locked(let reason): UninstallerCopy.locked(reason)
        }
    }

    var body: some View {
        SectionCard(padding: ADKTheme.Spacing.md) {
            HStack(alignment: .top, spacing: ADKTheme.Spacing.md) {
                Image(systemName: guidance.needsSettingsLink ? "hand.raised" : "lock").foregroundStyle(.adkReviewInk)
                Text(Self.text(guidance)).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                if guidance.needsSettingsLink {
                    Button(UninstallerCopy.openSettings) { NSWorkspace.shared.open(SystemSettingsLinks.appManagement) }
                }
                if guidance.needsReveal {
                    Button(UninstallerCopy.reveal) { FinderReveal.reveal(URL(fileURLWithPath: app.path)) }
                }
            }
        }
        .accessibilityElement(children: .contain)
    }
}
