import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum ProcessSort: Hashable {
    case memory, cpu
}

enum Level {
    case normal, warning, critical

    init(_ pressure: MemoryPressure) {
        switch pressure {
        case .normal: self = .normal
        case .warning: self = .warning
        case .critical: self = .critical
        }
    }

    var color: Color? {
        switch self {
        case .normal: nil
        case .warning: .orange
        case .critical: .red
        }
    }
}

@MainActor
final class StatsModel: ObservableObject {
    @Published var snapshot = Snapshot()
    @Published var sort: ProcessSort = .memory
    @Published private(set) var apps: [AppUsage] = []
    @Published private(set) var cpuValid = false
    @Published var hoveredProcessID: String?

    let coresDetail: String = {
        func sysctlInt(_ name: String) -> Int {
            var value: Int32 = 0
            var size = MemoryLayout<Int32>.size
            return sysctlbyname(name, &value, &size, nil, 0) == 0 ? Int(value) : 0
        }
        let total = ProcessInfo.processInfo.processorCount
        let performance = sysctlInt("hw.perflevel0.physicalcpu")
        let efficiency = sysctlInt("hw.perflevel1.physicalcpu")
        guard performance > 0, efficiency > 0 else { return String(localized: "\(total) cores") }
        return String(localized: "\(total) cores · \(performance) performance + \(efficiency) efficiency")
    }()

    /// Set by the app delegate; called when the user clicks "Quit" on a process row.
    var onQuitRequest: ((AppUsage) -> Void)?

    private var iconCache: [String: NSImage] = [:]

    var topApps: [AppUsage] {
        switch sort {
        case .memory: Array(apps.sorted { $0.memBytes > $1.memBytes }.prefix(5))
        case .cpu: cpuValid ? Array(apps.sorted { $0.cpuPercent > $1.cpuPercent }.prefix(5)) : []
        }
    }

    func update(apps: [AppUsage], cpuValid: Bool) {
        if cpuValid || !self.cpuValid {
            self.apps = apps
            self.cpuValid = cpuValid
        } else {
            // top's first sample after reopening the menu has no CPU figures yet; keep the previous ones meanwhile.
            let previousCPU = Dictionary(self.apps.map { ($0.id, $0.cpuPercent) }, uniquingKeysWith: +)
            self.apps = apps.map { app in
                var app = app
                app.cpuPercent = previousCPU[app.id] ?? 0
                return app
            }
        }
    }

    /// The last process list is kept so reopening the menu shows it right away while top takes a fresh sample.
    func menuDidClose() {
        hoveredProcessID = nil
    }

    func icon(for app: AppUsage) -> NSImage {
        let key = app.appPath ?? "<executable>"
        if let cached = iconCache[key] { return cached }
        let image = app.appPath.map { NSWorkspace.shared.icon(forFile: $0) }
            ?? NSWorkspace.shared.icon(for: .unixExecutable)
        image.size = NSSize(width: 16, height: 16)
        iconCache[key] = image
        return image
    }
}

enum Format {
    /// Decimal separators follow the user's region ("13.9" or "13,9").
    private static var locale: Locale { .current }

    static func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }

    /// Binary gigabytes with one decimal, as Activity Monitor shows memory: "13.9".
    static func gib(_ bytes: UInt64) -> String {
        String(format: "%.1f", locale: locale, Double(bytes) / Double(1 << 30))
    }

    /// Compact size for the menu bar: "5.3G" or "820M".
    static func compact(_ bytes: UInt64) -> String {
        let gib = Double(bytes) / Double(1 << 30)
        if gib >= 1 { return String(format: gib >= 10 ? "%.0fG" : "%.1fG", locale: locale, gib) }
        return "\(Int((Double(bytes) / Double(1 << 20)).rounded()))M"
    }

    /// Process memory: "4.1 GB" or "820 MB".
    static func memory(_ bytes: UInt64) -> String {
        let gib = Double(bytes) / Double(1 << 30)
        if gib >= 1 { return String(format: "%.1f GB", locale: locale, gib) }
        return "\(Int((Double(bytes) / Double(1 << 20)).rounded())) MB"
    }

    /// Decimal units, as Finder shows disk sizes: "370" / "1.2".
    static func disk(used: Int64, total: Int64) -> String {
        if total >= 1_000_000_000_000 {
            let tb = { (b: Int64) in String(format: "%.2f", locale: locale, Double(b) / 1e12) }
            return "\(tb(used)) / \(tb(total)) TB"
        }
        return "\(Int((Double(used) / 1e9).rounded())) / \(Int((Double(total) / 1e9).rounded())) GB"
    }

    /// Rate for the menu, in decimal units: "80 KB/s", "1.2 MB/s".
    static func rate(_ bytesPerSecond: Double) -> String {
        let kb = bytesPerSecond / 1000
        if kb < 1000 { return "\(Int(kb.rounded())) KB/s" }
        let mb = kb / 1000
        if mb < 1000 { return String(format: mb >= 100 ? "%.0f MB/s" : "%.1f MB/s", locale: locale, mb) }
        return String(format: "%.1f GB/s", locale: locale, mb / 1000)
    }

    /// Compact rate for the menu bar: "80K", "1.2M".
    static func compactRate(_ bytesPerSecond: Double) -> String {
        let kb = bytesPerSecond / 1000
        if kb < 1000 { return "\(Int(kb.rounded()))K" }
        let mb = kb / 1000
        if mb < 1000 { return String(format: mb >= 10 ? "%.0fM" : "%.1fM", locale: locale, mb) }
        return String(format: "%.1fG", locale: locale, mb / 1000)
    }

    static func pressure(_ pressure: MemoryPressure) -> String {
        switch pressure {
        case .normal: String(localized: "Normal pressure")
        case .warning: String(localized: "High pressure")
        case .critical: String(localized: "Critical pressure")
        }
    }

    static func thermal(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: String(localized: "Normal")
        case .fair: String(localized: "Fair")
        case .serious: String(localized: "Serious")
        case .critical: String(localized: "Critical")
        @unknown default: String(localized: "Unknown")
        }
    }

    static func cpu(_ percent: Double) -> String {
        percent < 1 && percent > 0 ? "<1%" : "\(Int(percent.rounded()))%"
    }
}
