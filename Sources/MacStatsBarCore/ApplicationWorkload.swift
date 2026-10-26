import Foundation

public struct ProcessActivity: Sendable {
    public let identity: ProcessIdentity
    public let parentPID: Int32
    public let cpuTime: UInt64?
    public let residentBytes: UInt64?
    public let bundleIdentifier: String?
    public init(identity: ProcessIdentity, parentPID: Int32, cpuTime: UInt64?, residentBytes: UInt64?,
                bundleIdentifier: String? = nil) {
        self.identity = identity; self.parentPID = parentPID; self.cpuTime = cpuTime
        self.residentBytes = residentBytes; self.bundleIdentifier = bundleIdentifier
    }
}

public enum ApplicationWorkload {
    public static func members(mainProcess: ProcessIdentity, bundlePath: String, bundleIdentifier: String? = nil,
                               processes: [ProcessActivity], otherApplicationPIDs: Set<Int32> = []) -> [ProcessActivity] {
        let byPID = Dictionary(processes.map { ($0.identity.pid, $0) }, uniquingKeysWith: { _, new in new })
        guard byPID[mainProcess.pid]?.identity == mainProcess else { return [] }
        return processes.filter { process in
            if process.identity == mainProcess { return true }
            var cursor = process
            var visited: Set<Int32> = []
            while true {
                guard visited.insert(cursor.identity.pid).inserted else { return false }
                if otherApplicationPIDs.contains(cursor.identity.pid) { return false }
                guard let parent = byPID[cursor.parentPID] else { break }
                // Snapshot races or reused parent PIDs cannot establish ancestry.
                guard parent.identity.startTime <= cursor.identity.startTime else { return false }
                if parent.identity == mainProcess { return true }
                cursor = parent
            }
            return process.identity.executable.hasPrefix(bundlePath + "/")
                || (bundleIdentifier != nil && process.bundleIdentifier == bundleIdentifier)
        }
    }

    public static func cpuPercent(current: [ProcessActivity], previous: [ProcessActivity], elapsed: TimeInterval) -> Double? {
        guard !current.isEmpty, elapsed.isFinite, elapsed > 0, elapsed <= 90,
              Set(current.map(\.identity)) == Set(previous.map(\.identity)),
              Set(current.map(\.identity.ownerUID)).count == 1,
              let total = totalCPU(current), let old = totalCPU(previous), total >= old else { return nil }
        return Double(total - old) / 1_000_000_000 / elapsed * 100
    }

    private static func totalCPU(_ processes: [ProcessActivity]) -> UInt64? {
        var total: UInt64 = 0
        for process in processes {
            guard let value = process.cpuTime else { return nil }
            let sum = total.addingReportingOverflow(value)
            guard !sum.overflow else { return nil }
            total = sum.partialValue
        }
        return total
    }
}
