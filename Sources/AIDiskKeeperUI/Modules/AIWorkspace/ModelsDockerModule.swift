import DiskKeeperCore
import SwiftUI

enum ModelsDockerModule: ModuleProvider {
    static let descriptor = ModuleDescriptor(id: .modelsDocker, section: .aiWorkspace, order: 3, symbol: "cube.transparent",
                                             isEnabled: true, listCategories: [.modelWeights, .docker])

    @MainActor static func badge(_ ctx: ModuleContext) -> ModuleBadge? {
        ModuleBadge.reclaimable(ctx.scan.totals, categories: [.modelWeights, .docker])
    }

    @MainActor static func statusModel(_ ctx: ModuleContext) -> DockerStatusModel {
        let env = ctx.env.pathEnvironment
        return ctx.suite.state(.modelsDocker) {
            DockerStatusModel(detect: {
                await DockerRuntimeDetector(layout: DockerRuntimeLayout.live(environment: env)).detect(home: env.home)
            })
        }
    }

    @MainActor static func makeDetail(_ ctx: ModuleContext) -> AnyView {
        AnyView(DockerModuleDetail(ctx: ctx, status: statusModel(ctx)))
    }
}

/// Refreshes the Docker card on appear, when a scan finishes and when a cleanup report arrives.
private struct DockerModuleDetail: View {
    let ctx: ModuleContext
    let status: DockerStatusModel

    var body: some View {
        VStack(spacing: 0) {
            DockerStatusCard(model: status)
            ScopedItemListView(ctx: ctx, scopeName: ModelsDockerModule.descriptor.title)
        }
        .onAppear { status.refresh() }
        .onChange(of: ctx.scan.scanGeneration) { status.refresh() }
        .onChange(of: ctx.suite.cleanup.lastReport?.results.count) { status.refresh() }
    }
}
