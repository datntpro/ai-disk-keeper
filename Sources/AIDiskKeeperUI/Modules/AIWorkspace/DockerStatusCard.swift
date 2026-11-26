import DiskKeeperCore
import SwiftUI

/// One row per detected runtime: state, disk image size, and why the file doesn't shrink right away.
/// There is no Start button: the app never starts or stops a runtime.
struct DockerStatusCard: View {
    let model: DockerStatusModel

    var body: some View {
        if !model.visible.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(model.visible) { DockerRuntimeRow(status: $0) }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            .padding([.horizontal, .top], 12)
        }
    }
}

struct DockerRuntimeRow: View {
    let status: DockerRuntimeStatus
    @State private var expanded = false

    var headline: String {
        let name = status.definition.displayName
        switch status.state {
        case .running(let v): return DockerCopy.running(name, v, state: DockerCopy.stateRunning)
        case .notRunning, .notInstalled: return DockerCopy.notRunning(name)
        case .timedOut: return DockerCopy.timedOut(name, seconds: "5")
        }
    }

    var sizes: String? {
        status.diskImage.map {
            DockerCopy.diskImageSizes(Formatting.bytes($0.allocatedBytes), Formatting.bytes($0.logicalBytes))
        }
    }

    var spoken: String { [headline, sizes].compactMap { $0 }.joined(separator: ", ") }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(headline).font(.callout)
            if let sizes { Text(sizes).font(.caption).foregroundStyle(.secondary) }
            if status.diskImage != nil {
                DisclosureGroup(DockerCopy.diskImageWhy, isExpanded: $expanded) {
                    Text(DockerCopy.diskImage(Formatting.bytes(status.diskImage?.allocatedBytes ?? 0),
                                              runtime: status.definition.displayName))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .font(.caption)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(spoken)
    }
}
