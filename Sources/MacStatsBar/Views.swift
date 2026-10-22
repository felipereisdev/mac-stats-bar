import SwiftUI

// MARK: - Menu bar

struct StatusBarView: View {
    @ObservedObject var model: StatsModel
    @ObservedObject var settings: Settings

    var body: some View {
        let s = model.snapshot
        let metrics = BarMetric.allCases.filter(settings.barMetrics.contains)
        HStack(spacing: 4) {
            ForEach(metrics) { metric in
                switch metric {
                case .cpu:
                    StatColumn(label: "CPU", value: Format.percent(s.cpu), level: settings.level(s.cpu))
                case .gpu:
                    StatColumn(label: "GPU", value: Format.percent(s.gpu), level: settings.level(s.gpu))
                case .ram:
                    StatColumn(label: "RAM", value: Format.percent(s.memFraction), level: settings.ramLevel(s))
                case .swap:
                    StatColumn(label: "SWAP", value: Format.compact(s.swapUsed), level: settings.level(s.swapFraction))
                case .disk:
                    StatColumn(label: "DISCO", value: Format.percent(s.diskFraction), level: settings.level(s.diskFraction))
                case .network:
                    TwoLineColumn(top: "↓" + Format.compactRate(s.netIn), bottom: "↑" + Format.compactRate(s.netOut))
                case .diskIO:
                    TwoLineColumn(top: "L " + Format.compactRate(s.diskRead), bottom: "G " + Format.compactRate(s.diskWrite))
                }
            }
            // Only shown when the Mac is hot enough to throttle.
            if s.thermal == .serious || s.thermal == .critical {
                Image(systemName: "thermometer.high")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(s.thermal == .critical ? Color.red : Color.orange)
                    .padding(.horizontal, 2)
            }
            if metrics.isEmpty && s.thermal != .serious && s.thermal != .critical {
                Image(systemName: "gauge.with.dots.needle.33percent")
                    .font(.system(size: 13))
            }
        }
        .padding(.horizontal, 4)
        .fixedSize()
    }
}

private struct StatColumn: View {
    let label: String
    let value: String
    let level: Level

    var body: some View {
        VStack(spacing: -2) {
            Text(label)
                .font(.system(size: 8, weight: .medium))
                .opacity(0.7)
            Text(value)
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
        }
        .foregroundStyle(level.color ?? .primary)
        .frame(width: 34)
    }
}

private struct TwoLineColumn: View {
    let top: String
    let bottom: String

    var body: some View {
        VStack(alignment: .leading, spacing: -1) {
            Text(top)
            Text(bottom)
        }
        .font(.system(size: 9.5, weight: .semibold).monospacedDigit())
        .frame(width: 42, alignment: .leading)
    }
}

// MARK: - Menu panel

struct MenuPanelView: View {
    @ObservedObject var model: StatsModel
    @ObservedObject var settings: Settings

    var body: some View {
        let s = model.snapshot
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 12) {
                MetricRow(name: "CPU", value: Format.percent(s.cpu), fraction: s.cpu, level: settings.level(s.cpu)) {
                    Text(model.coresDetail)
                }
                MetricRow(name: "GPU", value: Format.percent(s.gpu), fraction: s.gpu, level: settings.level(s.gpu)) {
                    EmptyView()
                }
                MetricRow(
                    name: "Memória",
                    value: "\(Format.gib(s.memUsed)) / \(Format.gib(s.memTotal)) GB",
                    fraction: s.memFraction,
                    level: settings.ramLevel(s)
                ) {
                    HStack(spacing: 0) {
                        StatusDot(color: s.pressure.dotColor)
                        Text(Format.pressure(s.pressure))
                        Text(" · Swap \(Format.gib(s.swapUsed)) / \(Format.gib(s.swapTotal)) GB")
                    }
                }
                MetricRow(
                    name: "Disco",
                    value: Format.disk(used: s.diskUsed, total: s.diskTotal),
                    fraction: s.diskFraction,
                    level: settings.level(s.diskFraction)
                ) {
                    Text("Leitura \(Format.rate(s.diskRead)) · Gravação \(Format.rate(s.diskWrite))")
                }
                HStack {
                    Text("Rede").fontWeight(.semibold)
                    Spacer()
                    Text("↓ \(Format.rate(s.netIn))   ↑ \(Format.rate(s.netOut))")
                        .monospacedDigit()
                }
                HStack(spacing: 0) {
                    Text("Temperatura").fontWeight(.semibold)
                    Spacer()
                    StatusDot(color: s.thermal.dotColor)
                    Text(Format.thermal(s.thermal))
                }
            }

            Divider().padding(.vertical, 12)

            Picker("", selection: $model.sort) {
                Text("Memória").tag(ProcessSort.memory)
                Text("CPU").tag(ProcessSort.cpu)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.bottom, 6)

            ProcessList(model: model)
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 4)
        .frame(width: 300)
    }
}

private struct MetricRow<Detail: View>: View {
    let name: String
    let value: String
    let fraction: Double
    let level: Level
    @ViewBuilder let detail: () -> Detail

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(name).fontWeight(.semibold)
                Spacer()
                Text(value)
                    .monospacedDigit()
                    .foregroundStyle(level.color ?? .primary)
            }
            UsageBar(fraction: fraction, color: level.color ?? .accentColor)
            detail()
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}

private struct StatusDot: View {
    let color: Color

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .padding(.trailing, 5)
    }
}

private extension MemoryPressure {
    var dotColor: Color {
        switch self {
        case .normal: .green
        case .warning: .orange
        case .critical: .red
        }
    }
}

private extension ProcessInfo.ThermalState {
    var dotColor: Color {
        switch self {
        case .nominal: .green
        case .fair: .yellow
        case .serious: .orange
        case .critical: .red
        @unknown default: .gray
        }
    }
}

private struct UsageBar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(color).frame(width: geo.size.width * fraction)
            }
        }
        .frame(height: 4)
    }
}

private struct ProcessList: View {
    @ObservedObject var model: StatsModel
    private let rowCount = 5

    var body: some View {
        let apps = model.topApps
        VStack(spacing: 0) {
            ForEach(0..<rowCount, id: \.self) { index in
                Group {
                    if apps.isEmpty {
                        SkeletonRow(nameWidth: skeletonNameWidths[index])
                    } else if index < apps.count {
                        row(apps[index])
                    } else {
                        Color.clear
                    }
                }
                .frame(height: 22)
            }
        }
        .font(.system(size: 12))
    }

    private let skeletonNameWidths: [CGFloat] = [118, 92, 136, 104, 78]

    private func row(_ app: AppUsage) -> some View {
        let hovered = model.hoveredProcessID == app.id
        return HStack(spacing: 8) {
            Image(nsImage: model.icon(for: app))
                .resizable()
                .frame(width: 16, height: 16)
            Text(app.name)
                .lineLimit(1)
                .truncationMode(.tail)
            if !app.canQuit {
                Image(systemName: "lock.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .help("Processo do sistema: não pode ser encerrado por aqui")
            }
            Spacer(minLength: 8)
            if hovered && app.canQuit {
                Button("Encerrar") { model.onQuitRequest?(app) }
                    .buttonStyle(QuitButtonStyle())
            } else {
                Text(model.sort == .memory ? Format.memory(app.memBytes) : Format.cpu(app.cpuPercent))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 6)
        .frame(maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(hovered ? Color.primary.opacity(0.08) : .clear)
        )
        .padding(.horizontal, -6)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside {
                model.hoveredProcessID = app.id
            } else if model.hoveredProcessID == app.id {
                model.hoveredProcessID = nil
            }
        }
    }
}

/// Placeholder row shown until top delivers its first sample (or, on the CPU tab, its first valid one).
private struct SkeletonRow: View {
    let nameWidth: CGFloat

    var body: some View {
        TimelineView(.animation) { context in
            let phase = (sin(context.date.timeIntervalSinceReferenceDate * 3) + 1) / 2
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 4).frame(width: 16, height: 16)
                RoundedRectangle(cornerRadius: 3).frame(width: nameWidth, height: 9)
                Spacer(minLength: 8)
                RoundedRectangle(cornerRadius: 3).frame(width: 42, height: 9)
            }
            .foregroundStyle(Color.primary.opacity(0.08 + 0.07 * phase))
        }
    }
}

private struct QuitButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color.red)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.red.opacity(configuration.isPressed ? 0.35 : 0.2)))
    }
}

// MARK: - Preferences

struct PreferencesView: View {
    @ObservedObject var settings: Settings

    var body: some View {
        Form {
            Section("Mostrar na barra de menus") {
                ForEach(BarMetric.allCases) { metric in
                    Toggle(metric.title, isOn: Binding(
                        get: { settings.barMetrics.contains(metric) },
                        set: { on in
                            if on { settings.barMetrics.insert(metric) } else { settings.barMetrics.remove(metric) }
                        }
                    ))
                }
            }
            Section("Cores") {
                Picker("Laranja a partir de", selection: $settings.warningThreshold) {
                    ForEach(Settings.thresholdOptions, id: \.self) { Text("\($0)%").tag($0) }
                }
                Picker("Vermelho a partir de", selection: $settings.criticalThreshold) {
                    ForEach(Settings.thresholdOptions, id: \.self) { Text("\($0)%").tag($0) }
                }
                Picker("Cor da RAM segue", selection: $settings.ramColorByPressure) {
                    Text("Pressão de memória").tag(true)
                    Text("Porcentagem usada").tag(false)
                }
            }
            Section("Geral") {
                Picker("Atualizar a cada", selection: $settings.refreshInterval) {
                    ForEach(Settings.intervalOptions, id: \.self) { seconds in
                        Text(seconds == 1 ? "1 segundo" : "\(Int(seconds)) segundos").tag(seconds)
                    }
                }
                Toggle("Abrir ao iniciar sessão", isOn: $settings.launchAtLogin)
            }
        }
        .formStyle(.grouped)
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
    }
}
