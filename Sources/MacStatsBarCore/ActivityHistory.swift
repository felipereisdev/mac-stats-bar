import Foundation

public enum ResourceKind: String, Sendable, Codable {
    case application, container, stoppedContainer
}

public struct ResourceID: Hashable, Sendable {
    public let kind: ResourceKind
    public let stableKey: String
    public let instanceKey: String
    public init(kind: ResourceKind, stableKey: String, instanceKey: String) {
        self.kind = kind; self.stableKey = stableKey; self.instanceKey = instanceKey
    }
}

public struct ResourceActivitySample: Sendable {
    public let resourceID: ResourceID
    public let name: String
    public let timestamp: TimeInterval
    public let cpuPercent: Double?
    public let memoryBytes: UInt64?
    public let networkRate: Double?
    public let blockRate: Double?
    public let isForeground: Bool
    public let eligible: Bool
    public let stoppedAt: Date?

    public init(resourceID: ResourceID, name: String, timestamp: TimeInterval,
                cpuPercent: Double? = nil, memoryBytes: UInt64? = nil,
                networkRate: Double? = nil, blockRate: Double? = nil,
                isForeground: Bool = false, eligible: Bool = true, stoppedAt: Date? = nil) {
        self.resourceID = resourceID; self.name = name; self.timestamp = timestamp
        self.cpuPercent = cpuPercent; self.memoryBytes = memoryBytes
        self.networkRate = networkRate; self.blockRate = blockRate
        self.isForeground = isForeground; self.eligible = eligible; self.stoppedAt = stoppedAt
    }
}

public struct ActivityHistory: Sendable {
    // Bounded to a little over an hour, including a boundary sample.
    var samples: [String: [ResourceActivitySample]] = [:]
    public init() {}

    public mutating func record(_ sample: ResourceActivitySample) {
        let key = sample.resourceID.stableKey
        var values = samples[key] ?? []
        if let last = values.last,
           last.resourceID != sample.resourceID || sample.timestamp < last.timestamp
            || sample.timestamp - last.timestamp > 90 {
            values = []
        }
        if values.last?.timestamp == sample.timestamp { _ = values.popLast() }
        values.append(sample)
        values.removeAll { $0.timestamp < sample.timestamp - 3690 }
        samples[key] = Array(values.suffix(750))
        if samples.count > 512, let oldest = samples.min(by: {
            ($0.value.last?.timestamp ?? 0) < ($1.value.last?.timestamp ?? 0)
        })?.key { samples.removeValue(forKey: oldest) }
    }

    public mutating func reset(resourceID: ResourceID) { samples.removeValue(forKey: resourceID.stableKey) }
    public mutating func resetAll() { samples.removeAll() }
    public mutating func retain(stableKeys: Set<String>) { samples = samples.filter { stableKeys.contains($0.key) } }
    public mutating func remove(kind: ResourceKind) {
        samples = samples.filter { $0.value.last?.resourceID.kind != kind }
    }
}

public enum ActivityRate {
    public static func bytesPerSecond(previous: UInt64?, current: UInt64?, elapsed: TimeInterval) -> Double? {
        guard let previous, let current, current >= previous, elapsed.isFinite, elapsed > 0, elapsed <= 90 else { return nil }
        return Double(current - previous) / elapsed
    }
}
