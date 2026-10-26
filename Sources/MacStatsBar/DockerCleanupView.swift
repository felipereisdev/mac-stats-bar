import MacStatsBarCore
import SwiftUI

struct DockerCleanupView: View {
    @ObservedObject var model: ResourceModel
    @ViewState private var showingReview = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let error = model.dockerError {
                    ResourceNotice(title: String(localized: "Docker is unavailable"), message: error, symbol: "exclamationmark.triangle")
                }
                Text("Free up Docker space").font(.title2.weight(.semibold))
                DockerRecommendedCleanupView(model: model) {
                    Task { if await model.prepareCleanup() { showingReview = true } }
                }
                if let report = model.pruneReport { PruneReportView(report: report) }
            }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(isPresented: $showingReview) {
            if let plan = model.prunePlan { PruneReviewView(model: model, plan: plan) }
        }
    }
}

private struct PruneReviewView: View {
    @ObservedObject var model: ResourceModel
    let plan: PrunePlan
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Clean up images and cache?", systemImage: "trash").font(.title2.weight(.semibold))
            Text("Removes images no container uses, including named images, and old build cache.")
            Label("All containers, their images, volumes and networks are kept.", systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
            Text("To use a removed image later, you will need to download or build it again. Future builds may take longer.")
                .font(.callout).foregroundStyle(.secondary)
            Text(verbatim: plan.endpoint.contextName).fontWeight(.medium)
            if let preview = model.cleanupPreview, preview.endpointIdentity == plan.endpoint.identity,
               let bytes = preview.estimatedBytes, bytes > 0 {
                Text("Estimated recovery: about \(ResourceFormat.size(bytes)).")
                if preview.isPartial {
                    Text("Partial estimate: some shared or unavailable data could not be included.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("The recovered space will be shown after cleanup.").foregroundStyle(.secondary)
            DisclosureGroup("Cleanup rules") {
                Text("Keeps recent images and targets a 2 GB build-cache reserve. Only cache unused for 7 days is eligible.")
                Text("Docker rechecks image references during cleanup. The recovered size will be shown when it finishes.")
            }.font(.caption).foregroundStyle(.secondary)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                VStack(alignment: .leading, spacing: 12) {
                    if context.date >= plan.expiresAt {
                        Text("This review expired. Cancel and review again.").foregroundStyle(.orange)
                    }
                    HStack {
                        Spacer()
                        Button("Cancel") { dismiss() }.disabled(model.isBusy).keyboardShortcut(.cancelAction)
                        Button("Clean up images and cache", role: .destructive) {
                            Task { await model.executeCleanup(); dismiss() }
                        }
                        .disabled(context.date >= plan.expiresAt || model.isBusy).keyboardShortcut(.defaultAction)
                    }
                }
            }
            if model.isBusy { ProgressView("Cleaning up…") }
        }.padding(28).frame(width: 540).interactiveDismissDisabled(model.isBusy)
    }
}

private struct PruneReportView: View {
    let report: PruneReport

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            DisclosureGroup("Cleanup details") {
                ForEach(report.results) { result in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(verbatim: result.category == .unusedImages
                                 ? String(localized: "Images no container uses") : String(localized: "Build cache"))
                                .fontWeight(.medium)
                            Spacer()
                            if let bytes = result.reclaimedBytes {
                                Text("Recovered: \(ResourceFormat.size(bytes))").monospacedDigit()
                            }
                        }
                        Text(verbatim: result.error ?? String(result.output.suffix(2000)))
                            .font(.caption.monospaced()).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if result.isInconclusive {
                            Text("The result is uncertain. Refresh before trying again.").foregroundStyle(.orange)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
