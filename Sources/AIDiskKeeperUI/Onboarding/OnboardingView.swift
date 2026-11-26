import DiskKeeperCore
import SwiftUI

public struct OnboardingView: View {
    @Bindable var model: SettingsModel
    let onboarding: OnboardingModel
    let dismiss: () -> Void
    @FocusState private var titleFocused: Bool

    public init(settings: SettingsModel, onboarding: OnboardingModel, dismiss: @escaping () -> Void) {
        self.model = settings
        self.onboarding = onboarding
        self.dismiss = dismiss
    }

    public var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(loc("onboarding.title", "AI Disk Keeper only looks until you say so."))
                        .font(.title2.bold()).focusable().focused($titleFocused)
                        .accessibilityAddTraits(.isHeader)
                    VStack(alignment: .leading, spacing: 6) {
                        bullet(loc("onboarding.readOnly", "Scanning is read-only."))
                        bullet(loc("onboarding.confirmFirst", "Nothing is cleaned until you review a cleanup plan and confirm it."))
                        bullet(loc("onboarding.trashAndLog", "Cleaned items go to the Trash, and every action is logged."))
                    }
                    section(loc("onboarding.scans.title", "What it scans")) {
                        if !model.availableTools.isEmpty {
                            Text(loc("onboarding.scans.tools", "Data from these AI tools: \(model.availableTools.map(\.name).joined(separator: ", "))."))
                        }
                        Text(loc("onboarding.scans.what", "Caches, logs, session history, and temp files in your home folder."))
                        Text(loc("onboarding.scans.never", "Never touched: credentials, settings and config, SSH and cloud keys, .env files, and anything outside your home folder."))
                            .fontWeight(.medium)
                        SettingsLink { Text(loc("onboarding.scanSettings", "Scan settings…")) }
                    }
                    FullDiskAccessCard(status: model.fdaStatus, recheck: model.refreshFullDiskAccess)
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Spacer()
                Button(loc("onboarding.notNow", "Not now")) { onboarding.finish(startScan: false); dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(loc("onboarding.startScan", "Start first scan")) { onboarding.finish(startScan: true); dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(minWidth: 560, idealWidth: 600, minHeight: 520, idealHeight: 580)
        .onAppear { titleFocused = true }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshFullDiskAccess()
        }
    }

    private func bullet(_ text: String) -> some View {
        Label(text, systemImage: "checkmark.circle").labelStyle(.titleAndIcon)
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            content()
        }
    }
}
