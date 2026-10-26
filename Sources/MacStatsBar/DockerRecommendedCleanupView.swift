import MacStatsBarCore
import SwiftUI

struct DockerRecommendedCleanupView: View {
    @ObservedObject var model: ResourceModel
    let review: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "trash.circle").font(.system(size: 30)).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Recommended cleanup").font(.title3.weight(.semibold))
                    Text("Your containers and their data will be kept.").foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                Label("Removes images no container uses", systemImage: "shippingbox")
                Label("Removes old build cache", systemImage: "wrench.and.screwdriver")
            }
            Divider()
            HStack(alignment: .center, spacing: 20) {
                estimateStatus
                Spacer()
                Button {
                    if model.cleanupPreview?.hasNoEstimatedWork == true { model.retry() }
                    else { review() }
                } label: {
                    if model.cleanupPreview?.hasNoEstimatedWork == true { Text("Refresh analysis") }
                    else { Text("Clean up images and cache…") }
                }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .accessibilityIdentifier("recommendedDockerCleanup")
                    .disabled(model.storage == nil || model.cleanupPreview == nil || model.dockerError != nil || model.isBusy
                              || model.isRefreshing)
            }
            if model.pruneReport != nil {
                Divider()
                cleanupStatus
            }
            Text("You may need to download images or rebuild them later.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(22).frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
    }

    @ViewBuilder
    private var estimateStatus: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let preview = model.cleanupPreview {
                if preview.hasNoEstimatedWork {
                    Text("Estimated recovery: \(ResourceFormat.size(0))")
                        .font(.title2.weight(.semibold)).monospacedDigit()
                    Text("The current rules preserve the remaining files.").font(.caption).foregroundStyle(.secondary)
                } else if let bytes = preview.estimatedBytes, bytes > 0 {
                    Text("About \(ResourceFormat.size(bytes))").font(.title2.weight(.semibold)).monospacedDigit()
                    Text("Estimated recovery with the current cleanup rules.").font(.caption).foregroundStyle(.secondary)
                    if preview.isPartial {
                        Text("Partial estimate: some shared or unavailable data could not be included.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text("Recovery estimate is incomplete").font(.headline)
                    Text("Some data could not be measured. Cleanup remains available for review.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !preview.hasNoEstimatedWork {
                    Text("The actual result can vary; Docker confirms it during cleanup.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else if model.isRefreshing {
                ProgressView("Analyzing cleanup candidates…").controlSize(.small)
            } else {
                Text("Refresh to analyze cleanup candidates.").foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var cleanupStatus: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let report = model.pruneReport {
                switch report.outcome {
                case .reclaimed(let bytes):
                    Text("Last cleanup: \(ResourceFormat.size(bytes)) freed")
                        .font(.title3.weight(.semibold)).monospacedDigit()
                    Text("Recovered space confirmed by Docker.").font(.caption).foregroundStyle(.secondary)
                case .noSpaceReclaimed:
                    Text("No additional space was freed").font(.headline)
                    Text("The last cleanup recovered 0 bytes with the current rules.")
                        .font(.caption).foregroundStyle(.secondary)
                case .completedWithoutMeasurement:
                    Text("Cleanup finished.").font(.headline)
                    Text("Docker did not report the recovered size.").font(.caption).foregroundStyle(.secondary)
                case .failed:
                    Text("Some items could not be cleaned.").font(.headline)
                    Text("Open cleanup details to see what happened.").font(.caption).foregroundStyle(.secondary)
                }
            } else if model.storage == nil && model.isRefreshing {
                ProgressView("Checking available space…").controlSize(.small)
            } else {
                Text("The recovered space will be shown after cleanup.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}
