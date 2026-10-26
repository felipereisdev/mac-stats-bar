import Foundation

public struct ContainerSummary: Sendable {
    public let totalCount: Int
    public let runningCount: Int
    public let cpuPercent: Double?
    public let memoryBytes: UInt64?

    public init(containers: [DockerContainer]) {
        totalCount = containers.count
        runningCount = containers.filter(\.isRunning).count
        let live = containers.filter(\.hasLiveMetrics)
        let cpu = live.compactMap(\.metrics.cpuPercent)
        let sum = cpu.reduce(0, +)
        cpuPercent = cpu.count == live.count && cpu.allSatisfy({ $0.isFinite && $0 >= 0 }) && sum.isFinite ? sum : nil
        var memory: UInt64 = 0
        var valid = true
        for container in live {
            guard let value = container.metrics.memoryBytes else { valid = false; break }
            let sum = memory.addingReportingOverflow(value)
            guard !sum.overflow else { valid = false; break }
            memory = sum.partialValue
        }
        memoryBytes = valid ? memory : nil
    }
}
