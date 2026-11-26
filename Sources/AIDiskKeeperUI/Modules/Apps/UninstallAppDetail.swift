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
                    if let g = model.guidance(for: app) { UninstallGuidanceCard(guidance: g, app: app, model: model, coordinator: coordinator) }
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
                Text(UninstallerCopy.total(Formatting.bytes(app.sizeAllocated), Formatting.count(group.related.count + group.shared.count),
                                              count: group.related.count + group.shared.count))
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
                Text(model.leftoversFailed ? UninstallerCopy.relatedFailed : UninstallerCopy.noRelated).font(.callout).foregroundStyle(.adkText3)
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
                        UninstallRelatedRow(item: item, kind: .shared, owners: model.ownerNames(of: item),
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
                Text(UninstallerCopy.noteBody).font(.callout).foregroundStyle(.adkText2)
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
        UninstallActionBar(model: model, availability: availability, help: uninstallHelp, coordinator: coordinator)
    }
}

/// The bottom bar: how much will go, and Reset / Uninstall. One row when it fits; otherwise the buttons drop
/// below the summary (long Vietnamese copy at the narrowest detail width).
struct UninstallActionBar: View {
    var model: UninstallerModel
    let availability: UninstallAvailability
    let help: String
    let coordinator: CleanupCoordinator

    private var size: some View { SizeText(model.tickedBytes, qualifier: .upTo).font(.headline).fixedSize() }
    private var summary: some View {
        Text(UninstallerCopy.barSummary(Formatting.count(model.tickedRelated.count), count: model.tickedRelated.count))
            .foregroundStyle(.adkText2).lineLimit(2).fixedSize(horizontal: false, vertical: true)
    }
    private var buttons: some View {
        HStack(spacing: ADKTheme.Spacing.md) {
            Button(UninstallerCopy.reset) { model.resetApp(using: coordinator) }
                .disabled(!model.canReset).help(UninstallerCopy.resetHelp).fixedSize()
            Button(UninstallerCopy.uninstall) { model.uninstall(using: coordinator) }
                .buttonStyle(.borderedProminent).tint(.adkAccent)
                .disabled(availability != .available).help(help).fixedSize()
        }
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: ADKTheme.Spacing.md) { size; summary; Spacer(minLength: 0); buttons }
            VStack(alignment: .leading, spacing: ADKTheme.Spacing.sm) {
                HStack(alignment: .firstTextBaseline, spacing: ADKTheme.Spacing.md) { size; summary }
                HStack { Spacer(minLength: 0); buttons }
            }
        }
        .font(.callout)
        .padding(.horizontal, ADKTheme.Spacing.lg).padding(.vertical, ADKTheme.Spacing.md)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .overlay(alignment: .top) { Rectangle().fill(.adkLine).frame(height: ADKTheme.hairline) }
    }
}

/// A guidance card: what stops the uninstall (or what macOS wants), and the one thing to do about it.
struct UninstallGuidanceCard: View {
    let guidance: UninstallGuidance
    let app: InstalledApp
    var model: UninstallerModel
    var coordinator: CleanupCoordinator?

    init(guidance: UninstallGuidance, app: InstalledApp, model: UninstallerModel, coordinator: CleanupCoordinator? = nil) {
        self.guidance = guidance
        self.app = app
        self.model = model
        self.coordinator = coordinator
    }

    static func text(_ g: UninstallGuidance) -> String {
        switch g {
        case .appManagement: UninstallerCopy.guideAppManagement
        case .requiresAdmin: UninstallerCopy.guideAdmin
        case .running(let name, let quit, let background, let otherUser, let canQuit):
            runningText(name: name, quit: quit, background: background, otherUser: otherUser, canQuit: canQuit)
        case .runningUnknown(let name): UninstallerCopy.quitUnknown(name)
        case .selfApp: UninstallerCopy.selfApp
        case .quitDone(let name): UninstallerCopy.quitDone(name)
        case .locked(let reason): UninstallerCopy.locked(reason)
        }
    }

    private static func runningText(name: String, quit: QuitFlowState?, background: [String], otherUser: Bool, canQuit: Bool) -> String {
        switch quit {
        case .stuck?: return UninstallerCopy.quitStuck(name)
        case .failed?: return UninstallerCopy.quitFailed(name)
        case .auditFailed?: return UninstallerCopy.auditFailed
        case .relaunched?: return UninstallerCopy.relaunched(name)
        case .backgroundRemains? where !background.isEmpty: return UninstallerCopy.background(name, UninstallerCopy.list(background))
        case .refused(.selfApp)?: return UninstallerCopy.selfApp
        case .refused(.otherUser)?: return UninstallerCopy.otherUser(name)
        case nil where !canQuit && !background.isEmpty: return UninstallerCopy.background(name, UninstallerCopy.list(background))
        case nil where !canQuit && otherUser: return UninstallerCopy.otherUser(name)
        default: return UninstallerCopy.guideRunning(name)
        }
    }

    private var icon: String {
        switch guidance {
        case .appManagement: "hand.raised"
        case .quitDone: "checkmark.circle"
        default: "lock"
        }
    }

    var body: some View {
        SectionCard(padding: ADKTheme.Spacing.md) {
            HStack(alignment: .top, spacing: ADKTheme.Spacing.md) {
                Image(systemName: icon).foregroundStyle(.adkReviewInk)
                VStack(alignment: .leading, spacing: ADKTheme.Spacing.sm) {
                    Text(Self.text(guidance)).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                    if hasControls { controls }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .confirmationDialog(UninstallerCopy.forceTitle(app.name), isPresented: forcePresented, titleVisibility: .visible) {
            Button(UninstallerCopy.forceAction, role: .destructive) { model.confirmForceQuit() }
            Button(UninstallerCopy.forceCancel, role: .cancel) { model.cancelForceQuit() }
        } message: {
            let n = model.forceConfirmation?.instances ?? 1
            Text(n > 1 ? "\(UninstallerCopy.forceMessage(app.name))\n\(UninstallerCopy.forceInstances(n))" : UninstallerCopy.forceMessage(app.name))
        }
        .onChange(of: model.quitFlows[app.id]) { _, new in
            if new == .done { AccessibilityNotification.Announcement(UninstallerCopy.a11yQuit(app.name)).post() }
        }
    }

    /// Buttons sit under the text, in one row when they fit and stacked when they don't.
    @ViewBuilder private var controls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: ADKTheme.Spacing.sm) { controlButtons }
            VStack(alignment: .leading, spacing: ADKTheme.Spacing.sm) { controlButtons }
        }
    }

    private var hasControls: Bool {
        if guidance.needsSettingsLink || guidance.needsReveal { return true }
        switch guidance {
        case .running, .runningUnknown: return true
        default: return false
        }
    }

    @ViewBuilder private var controlButtons: some View {
        if guidance.needsSettingsLink {
            Button(UninstallerCopy.openSettings) { NSWorkspace.shared.open(SystemSettingsLinks.appManagement) }
        }
        if guidance.needsReveal {
            Button(UninstallerCopy.reveal) { FinderReveal.reveal(URL(fileURLWithPath: app.path)) }
        }
        quitControls
    }

    private var forcePresented: Binding<Bool> {
        Binding(get: { model.forceConfirmation?.appID == app.id },
                set: { if !$0 { DispatchQueue.main.async { model.cancelForceQuit() } } })
    }

    @ViewBuilder private var quitControls: some View {
        switch guidance {
        case .running(_, let quit, _, _, let canQuit):
            if quit?.isBusy == true {
                ProgressView().controlSize(.small)
                Text(UninstallerCopy.quitting).font(.callout).foregroundStyle(.adkText2)
            } else {
                if canQuit {
                    Button(UninstallerCopy.quitButton) { model.quit(app, coordinator: coordinator) }
                        .disabled(coordinator?.isPresented == true).help(UninstallerCopy.quitHelp)
                }
                if quit?.isStuck == true {
                    Button(UninstallerCopy.showApp) { model.showApp(app) }
                    Button(UninstallerCopy.forceQuit, role: .destructive) { model.requestForceQuit(app) }
                        .disabled(coordinator?.isPresented == true)
                }
            }
        case .runningUnknown:
            Button(UninstallerCopy.checkAgain) { model.refreshRunning() }
        default: EmptyView()
        }
    }
}
