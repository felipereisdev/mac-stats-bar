import Foundation
import ServiceManagement

enum BarMetric: String, CaseIterable, Identifiable {
    case cpu, gpu, ram, swap, disk, network, diskIO

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .ram: "RAM"
        case .swap: "Swap"
        case .disk: "Disco (espaço)"
        case .network: "Rede"
        case .diskIO: "Atividade do disco"
        }
    }
}

/// User preferences, persisted in UserDefaults.
@MainActor
final class Settings: ObservableObject {
    static let thresholdOptions = [50, 60, 70, 75, 80, 85, 90, 95]
    static let intervalOptions: [Double] = [1, 2, 5]

    private let defaults = UserDefaults.standard

    @Published var barMetrics: Set<BarMetric> {
        didSet { defaults.set(barMetrics.map(\.rawValue), forKey: "barMetrics") }
    }
    @Published var warningThreshold: Int {
        didSet { defaults.set(warningThreshold, forKey: "warningThreshold") }
    }
    @Published var criticalThreshold: Int {
        didSet { defaults.set(criticalThreshold, forKey: "criticalThreshold") }
    }
    /// When true, the RAM color follows memory pressure instead of the used percentage.
    @Published var ramColorByPressure: Bool {
        didSet { defaults.set(ramColorByPressure, forKey: "ramColorByPressure") }
    }
    @Published var refreshInterval: Double {
        didSet { defaults.set(refreshInterval, forKey: "refreshInterval") }
    }
    @Published var launchAtLogin: Bool {
        didSet { applyLaunchAtLogin() }
    }

    init() {
        if let saved = defaults.stringArray(forKey: "barMetrics") {
            barMetrics = Set(saved.compactMap(BarMetric.init(rawValue:)))
        } else {
            barMetrics = [.cpu, .gpu, .ram, .swap, .disk]
        }
        warningThreshold = defaults.object(forKey: "warningThreshold") as? Int ?? 80
        criticalThreshold = defaults.object(forKey: "criticalThreshold") as? Int ?? 90
        ramColorByPressure = defaults.object(forKey: "ramColorByPressure") as? Bool ?? true
        refreshInterval = defaults.object(forKey: "refreshInterval") as? Double ?? 2
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func level(_ fraction: Double) -> Level {
        let percent = fraction * 100
        if percent >= Double(criticalThreshold) { return .critical }
        if percent >= Double(warningThreshold) { return .warning }
        return .normal
    }

    func ramLevel(_ snapshot: Snapshot) -> Level {
        ramColorByPressure ? Level(snapshot.pressure) : level(snapshot.memFraction)
    }

    private func applyLaunchAtLogin() {
        let enabled = SMAppService.mainApp.status == .enabled
        guard launchAtLogin != enabled else { return }
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("MacStatsBar: could not change login item: \(error)")
            // Reflect the real state in the UI.
            DispatchQueue.main.async { self.launchAtLogin = SMAppService.mainApp.status == .enabled }
        }
    }
}
