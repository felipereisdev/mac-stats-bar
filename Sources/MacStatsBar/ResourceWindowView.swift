import SwiftUI

struct ResourceWindowView: View {
    @ObservedObject var model: ResourceModel
    @ObservedObject var settings: Settings

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "shippingbox").foregroundStyle(.secondary)
                Text("Resources").font(.title3.weight(.semibold))
                if let endpoint = model.endpoint {
                    Text(verbatim: endpoint.contextName).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if model.isBusy {
                    ProgressView().controlSize(.small)
                    Text("Working…").foregroundStyle(.secondary)
                } else if model.isRefreshing {
                    ProgressView().controlSize(.small)
                }
                Button { model.retry() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .disabled(model.isBusy || model.isRefreshing).keyboardShortcut("r")
            }.padding()
            if let feedback = model.feedback {
                HStack(alignment: .top) {
                    Text(verbatim: feedback).font(.callout).textSelection(.enabled)
                    Spacer()
                    Button { model.clearFeedback() } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).accessibilityLabel("Dismiss")
                }.padding(12).background(.quaternary)
            }
            TabView(selection: $model.selectedTab) {
                DockerCleanupView(model: model)
                    .tabItem { Label("Clean Docker", systemImage: "trash") }.tag(ResourceTab.cleanup)
                ResourceSuggestionsView(model: model, settings: settings)
                    .tabItem { Label("Free memory", systemImage: "memorychip") }.tag(ResourceTab.suggestions)
            }.padding([.horizontal, .bottom], 12)
        }.frame(minWidth: 880, minHeight: 560)
    }
}
