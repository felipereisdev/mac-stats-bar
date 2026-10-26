import Foundation

public struct RecommendationPolicy: Sendable {
    public let window: TimeInterval
    public let excludedKeys: Set<String>
    public let ignoredUntil: [String: Date]
    public init(window: TimeInterval = 900, excludedKeys: Set<String> = [], ignoredUntil: [String: Date] = [:]) {
        self.window = [900.0, 1800, 3600].contains(window) ? window : 900
        self.excludedKeys = excludedKeys; self.ignoredUntil = ignoredUntil
    }
}

public struct ResourceRecommendation: Sendable, Identifiable {
    public var id: String { resourceID.stableKey }
    public let resourceID: ResourceID
    public let name: String
    public let observedDuration: TimeInterval
    public let memoryBytes: UInt64?
}

public enum RecommendationEngine {
    public static func suggest(history: ActivityHistory, policy: RecommendationPolicy,
                               now: TimeInterval, wallTime: Date = Date()) -> [ResourceRecommendation] {
        history.samples.values.compactMap { samples -> ResourceRecommendation? in
            guard let last = samples.last, last.timestamp <= now, now - last.timestamp <= 90,
                  last.eligible, last.resourceID.kind != .stoppedContainer,
                  !policy.excludedKeys.contains(last.resourceID.stableKey),
                  (policy.ignoredUntil[last.resourceID.stableKey] ?? .distantPast) <= wallTime else { return nil }

            if last.resourceID.kind == .application, (last.memoryBytes ?? 0) < 256 * 1_048_576 { return nil }
            if last.resourceID.kind == .container, (last.memoryBytes ?? 0) == 0 { return nil }
            var quiet: [ResourceActivitySample] = []
            for sample in samples {
                let cpuIsQuiet = sample.cpuPercent.map { $0.isFinite && $0 >= 0 && $0 < 1 } ?? false
                var isQuiet = sample.eligible && !sample.isForeground && cpuIsQuiet
                if sample.resourceID.kind == .container {
                    isQuiet = isQuiet
                        && (sample.networkRate.map { $0.isFinite && $0 >= 0 && $0 < 1024 } ?? false)
                        && (sample.blockRate.map { $0.isFinite && $0 >= 0 && $0 < 4096 } ?? false)
                }
                if isQuiet { quiet.append(sample) } else { quiet.removeAll(keepingCapacity: true) }
            }
            let cutoff = now - policy.window
            guard let first = quiet.first, first.timestamp <= cutoff,
                  let anchor = quiet.lastIndex(where: { $0.timestamp <= cutoff }) else { return nil }
            let window = Array(quiet[anchor...])
            let expectedCount = Int(policy.window / 30) + 1
            // A burst of fast samples cannot compensate for missing 30-second intervals.
            let coveredIntervals = Set(window.filter { $0.timestamp >= cutoff }.map {
                Int(($0.timestamp - cutoff) / 30)
            }).count
            guard coveredIntervals >= Int(ceil(Double(expectedCount) * 0.8)),
                  zip(window, window.dropFirst()).allSatisfy({ $1.timestamp - $0.timestamp <= 90 }) else { return nil }
            return ResourceRecommendation(resourceID: last.resourceID, name: last.name,
                                          observedDuration: now - first.timestamp, memoryBytes: last.memoryBytes)
        }.sorted { ($0.memoryBytes ?? 0) > ($1.memoryBytes ?? 0) }
    }
}
