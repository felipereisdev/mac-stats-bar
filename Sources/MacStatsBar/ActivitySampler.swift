import AppKit
import Darwin
import MacStatsBarCore

struct ApplicationDescriptor: Sendable {
    let name: String
    let bundlePath: String
    let mainProcess: ProcessIdentity
    let bundleIdentifier: String?
}

struct ObservedApplication: Sendable {
    let descriptor: ApplicationDescriptor
    let members: Set<ProcessIdentity>
    let sample: ResourceActivitySample
}

/// libproc work is actor-isolated away from AppKit and the main thread.
actor ActivitySampler {
    private struct Previous {
        let members: [ProcessActivity]
        let timestamp: TimeInterval
    }
    private var previous: [String: Previous] = [:]

    func reset() { previous.removeAll() }

    func sample(applications: [ApplicationDescriptor], foregroundPath: String?) -> [ObservedApplication] {
        let timestamp = ProcessInfo.processInfo.systemUptime
        let estimated = max(1024, Int(proc_listallpids(nil, 0)) + 256)
        var pids = [pid_t](repeating: 0, count: estimated)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.stride)))
        guard count > 0, count <= pids.count else { previous.removeAll(); return [] }
        var processes: [ProcessActivity] = []
        var bundleCache: [String: String] = [:]
        for pid in pids.prefix(count) {
            guard let inspected = ProcessIdentity.inspect(pid: pid) else { continue }
            let identity = inspected.identity
            var task = proc_taskinfo()
            let size = Int32(MemoryLayout<proc_taskinfo>.stride)
            let readable = identity.ownerUID == getuid() && !identity.executable.isEmpty
                && proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, size) == size
            let cpu = task.pti_total_user.addingReportingOverflow(task.pti_total_system)
            let bundle = Self.bundleIdentifier(for: identity.executable, cache: &bundleCache)
            processes.append(ProcessActivity(identity: identity, parentPID: inspected.parentPID,
                                               cpuTime: readable && !cpu.overflow ? cpu.partialValue : nil,
                                               residentBytes: readable ? task.pti_resident_size : nil,
                                               bundleIdentifier: bundle))
        }
        var next: [String: Previous] = [:]
        let applicationPIDs = Set(applications.map(\.mainProcess.pid))
        let result = applications.compactMap { descriptor -> ObservedApplication? in
            let members = ApplicationWorkload.members(mainProcess: descriptor.mainProcess, bundlePath: descriptor.bundlePath,
                                                       bundleIdentifier: descriptor.bundleIdentifier, processes: processes,
                                                       otherApplicationPIDs: applicationPIDs.subtracting([descriptor.mainProcess.pid]))
            guard descriptor.mainProcess.isCurrent, members.contains(where: { $0.identity == descriptor.mainProcess }) else { return nil }
            let key = descriptor.bundlePath
            let old = previous[key]
            let cpu = old.flatMap {
                ApplicationWorkload.cpuPercent(current: members, previous: $0.members, elapsed: timestamp - $0.timestamp)
            }
            let complete = members.allSatisfy {
                $0.identity.ownerUID == getuid() && $0.cpuTime != nil && $0.residentBytes != nil
            }
            var memory: UInt64 = 0
            var overflow = false
            for member in members {
                let sum = memory.addingReportingOverflow(member.residentBytes ?? 0)
                memory = sum.partialValue
                overflow = overflow || sum.overflow
            }
            if complete { next[key] = Previous(members: members, timestamp: timestamp) }
            let id = ResourceID(kind: .application, stableKey: "app:" + key, instanceKey: descriptor.mainProcess.instanceKey)
            let reading = ResourceActivitySample(resourceID: id, name: descriptor.name, timestamp: timestamp,
                                                  cpuPercent: cpu, memoryBytes: overflow ? nil : memory,
                                                  isForeground: foregroundPath == key, eligible: complete && !overflow)
            return ObservedApplication(descriptor: descriptor, members: Set(members.map(\.identity)), sample: reading)
        }
        previous = next
        return result
    }

    private static func bundleIdentifier(for path: String, cache: inout [String: String]) -> String? {
        let components = (path as NSString).pathComponents
        guard let index = components.firstIndex(where: { $0.hasSuffix(".app") || $0.hasSuffix(".app.bundle") }) else { return nil }
        let bundlePath = NSString.path(withComponents: Array(components[...index]))
        let identifier: String
        if let cached = cache[bundlePath] { identifier = cached }
        else {
            identifier = Bundle(path: bundlePath)?.bundleIdentifier ?? ""
            cache[bundlePath] = identifier
        }
        return identifier.isEmpty ? nil : identifier
    }
}

@MainActor
enum ApplicationDescriptors {
    static func current() -> [ApplicationDescriptor] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy == .regular, app.processIdentifier != getpid(),
                  let url = app.bundleURL, !url.path.hasPrefix("/System/"),
                  !url.path.hasPrefix("/Library/Apple/"),
                  let identity = ProcessIdentity.read(pid: app.processIdentifier),
                  identity.ownerUID == getuid() else { return nil }
            return ApplicationDescriptor(name: app.localizedName ?? url.deletingPathExtension().lastPathComponent,
                                         bundlePath: url.path, mainProcess: identity, bundleIdentifier: app.bundleIdentifier)
        }
    }
}
