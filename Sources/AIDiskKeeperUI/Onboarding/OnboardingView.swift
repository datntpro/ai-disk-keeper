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
                    Text("AI Disk Keeper only looks until you say so.")
                        .font(.title2.bold()).focusable().focused($titleFocused)
                        .accessibilityAddTraits(.isHeader)
                    VStack(alignment: .leading, spacing: 6) {
                        bullet("Scanning is read-only.")
                        bullet("Nothing is cleaned until you review a cleanup plan and confirm it.")
                        bullet("Cleaned items go to the Trash, and every action is logged.")
                    }
                    section("What it scans") {
                        if !model.availableTools.isEmpty {
                            Text("Data from these AI tools: " + model.availableTools.map(\.name).joined(separator: ", ") + ".")
                        }
                        Text("Caches, logs, session history, and temp files in your home folder.")
                        Text("Never touched: credentials, settings and config, SSH and cloud keys, .env files, and anything outside your home folder.")
                            .fontWeight(.medium)
                        SettingsLink { Text("Scan settings…") }
                    }
                    FullDiskAccessCard(status: model.fdaStatus, recheck: model.refreshFullDiskAccess)
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Spacer()
                Button("Not now") { onboarding.finish(startScan: false); dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Start first scan") { onboarding.finish(startScan: true); dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 560, height: 520)
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
