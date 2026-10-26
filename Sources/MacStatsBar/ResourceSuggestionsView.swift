import MacStatsBarCore
import SwiftUI

struct ResourceSuggestionsView: View {
    @ObservedObject var model: ResourceModel
    @ObservedObject var settings: Settings

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Free memory").font(.title2.weight(.semibold))
                Spacer()
                Toggle("Observe activity", isOn: $settings.activitySuggestionsEnabled).toggleStyle(.switch)
            }
            Text("Find running apps and containers with little activity. Closing them may free memory. Observation continues in the background; you review every action.")
                .foregroundStyle(.secondary)
            if !settings.activitySuggestionsEnabled {
                Spacer()
                ResourceNotice(title: String(localized: "Activity observation is off"),
                               message: String(localized: "Enable observation to build a local history for apps and containers. Nothing is stopped automatically."),
                               symbol: "pause.circle")
                Spacer()
            } else {
                Picker("Observation window", selection: $settings.activityWindowMinutes) {
                    Text("15 minutes").tag(15); Text("30 minutes").tag(30); Text("60 minutes").tag(60)
                }.frame(maxWidth: 350)
                if let error = model.dockerError {
                    Label { Text(verbatim: error).font(.caption) } icon: { Image(systemName: "shippingbox") }
                        .foregroundStyle(.secondary)
                }
                if model.recommendations.isEmpty {
                    Spacer()
                    ResourceNotice(title: String(localized: "Observing activity"),
                                   message: String(localized: "Suggestions appear after a complete quiet observation window. Active, protected and insufficiently observed resources are excluded."),
                                   symbol: "clock")
                    Spacer()
                } else {
                    List(model.recommendations) { recommendation in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: recommendation.resourceID.kind == .application ? "app" : "shippingbox")
                                .font(.title3).foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(verbatim: recommendation.name).font(.headline)
                                Text("Low activity observed for \(Int(recommendation.observedDuration / 60)) minutes. Review before stopping.")
                                if let memory = recommendation.memoryBytes {
                                    Text("Observed memory: \(Format.memory(memory))").foregroundStyle(.secondary)
                                }
                                HStack {
                                    Button("Ignore for 24 hours") { model.ignore(recommendation, permanently: false) }
                                    Button("Never suggest") { model.ignore(recommendation, permanently: true) }
                                }.buttonStyle(.link).font(.caption)
                            }
                            Spacer()
                            Button(actionTitle(recommendation), role: .destructive) {
                                Task { await model.act(on: recommendation) }
                            }.disabled(model.isBusy || model.isRefreshing
                                       || (recommendation.resourceID.kind != .application && !model.canAct))
                        }.padding(.vertical, 10)
                    }
                }
                Text("Apps need at least 256 MiB of observed memory and no foreground activation. Container suggestions exclude persistent mounts and protected infrastructure.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(24)
    }

    private func actionTitle(_ value: ResourceRecommendation) -> String {
        switch value.resourceID.kind {
        case .application: String(localized: "Quit…")
        case .container: String(localized: "Stop…")
        case .stoppedContainer: String(localized: "Stop…")
        }
    }
}
