import DiskKeeperCore
import SwiftUI

@main
struct AIDiskKeeperApp: App {
    var body: some Scene {
        WindowGroup("AI Disk Keeper") {
            ContentView()
        }
    }
}

struct ContentView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "externaldrive.badge.checkmark")
                .font(.system(size: 48))
            Text("AI Disk Keeper")
                .font(.title)
            Text("Scaffold build \(DiskKeeperCore.version). Scanning arrives in M1.")
                .foregroundStyle(.secondary)
        }
        .padding(40)
        .frame(minWidth: 480, minHeight: 320)
    }
}
