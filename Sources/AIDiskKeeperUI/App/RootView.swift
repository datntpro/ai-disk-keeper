import SwiftUI

public struct RootView: View {
    let env: AppEnvironment
    @State private var scan: ScanViewModel

    public init(env: AppEnvironment) {
        self.env = env
        _scan = State(initialValue: ScanViewModel(makeEngine: env.makeScanEngine))
    }

    public var body: some View {
        Text("AI Disk Keeper").frame(minWidth: 480, minHeight: 320)
    }
}
