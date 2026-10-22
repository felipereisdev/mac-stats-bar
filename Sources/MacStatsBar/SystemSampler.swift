import Darwin
import Foundation
import IOKit

struct Snapshot {
    var cpu: Double = 0
    var gpu: Double = 0
    var memUsed: UInt64 = 0
    var memTotal: UInt64 = 0
    var swapUsed: UInt64 = 0
    var swapTotal: UInt64 = 0
    var diskUsed: Int64 = 0
    var diskTotal: Int64 = 0
    var pressure: MemoryPressure = .normal
    /// Bytes per second.
    var netIn: Double = 0
    var netOut: Double = 0
    var diskRead: Double = 0
    var diskWrite: Double = 0
    var thermal: ProcessInfo.ThermalState = .nominal

    var memFraction: Double { fraction(Double(memUsed), Double(memTotal)) }
    var swapFraction: Double { fraction(Double(swapUsed), Double(swapTotal)) }
    var diskFraction: Double { fraction(Double(diskUsed), Double(diskTotal)) }

    private func fraction(_ used: Double, _ total: Double) -> Double {
        total > 0 ? min(max(used / total, 0), 1) : 0
    }
}

enum MemoryPressure {
    case normal, warning, critical
}

/// Reads system-wide CPU, GPU, memory, swap and disk usage without elevated privileges.
final class SystemSampler {
    private let host = mach_host_self()
    private var lastCPUTicks: (busy: UInt64, total: UInt64)?
    private var lastDiskRead: Date = .distantPast
    private var cachedDisk: (used: Int64, total: Int64) = (0, 0)
    private var lastIO: (time: TimeInterval, counters: IOCounters)?

    private struct IOCounters {
        var network: [String: (bytesIn: UInt64, bytesOut: UInt64)] = [:]
        var diskRead: UInt64 = 0, diskWrite: UInt64 = 0
    }

    func sample(previous: Snapshot) -> Snapshot {
        var s = Snapshot()
        s.cpu = cpuUsage() ?? previous.cpu
        s.gpu = gpuUsage() ?? previous.gpu
        (s.memUsed, s.memTotal) = memoryUsage()
        (s.swapUsed, s.swapTotal) = swapUsage()
        // Disk usage changes slowly and the "important usage" query is relatively expensive.
        if Date().timeIntervalSince(lastDiskRead) > 30 {
            cachedDisk = diskUsage() ?? cachedDisk
            lastDiskRead = Date()
        }
        (s.diskUsed, s.diskTotal) = cachedDisk
        s.pressure = memoryPressure()
        s.thermal = ProcessInfo.processInfo.thermalState

        let now = ProcessInfo.processInfo.systemUptime
        var counters = IOCounters()
        counters.network = networkBytes()
        (counters.diskRead, counters.diskWrite) = diskIOBytes()
        if let last = lastIO, now > last.time {
            let elapsed = now - last.time
            // Counters can reset (interface or disk going away); report 0 instead of a bogus spike.
            func rate(_ current: UInt64, _ previous: UInt64) -> Double {
                current >= previous ? Double(current - previous) / elapsed : 0
            }
            // Interface counters are only 32 bits wide for unprivileged processes and wrap every 4 GB,
            // so take each interface's delta modulo 2^32 (one wrap per interval is plenty at these rates).
            var deltaIn: UInt64 = 0, deltaOut: UInt64 = 0
            for (interface, current) in counters.network {
                guard let previous = last.counters.network[interface] else { continue }
                deltaIn += UInt64(UInt32(truncatingIfNeeded: current.bytesIn &- previous.bytesIn))
                deltaOut += UInt64(UInt32(truncatingIfNeeded: current.bytesOut &- previous.bytesOut))
            }
            s.netIn = Double(deltaIn) / elapsed
            s.netOut = Double(deltaOut) / elapsed
            s.diskRead = rate(counters.diskRead, last.counters.diskRead)
            s.diskWrite = rate(counters.diskWrite, last.counters.diskWrite)
        }
        lastIO = (now, counters)
        return s
    }

    private func cpuUsage() -> Double? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        let user = UInt64(info.cpu_ticks.0), system = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2), nice = UInt64(info.cpu_ticks.3)
        let busy = user + system + nice
        let total = busy + idle
        defer { lastCPUTicks = (busy, total) }
        guard let last = lastCPUTicks, total > last.total else { return nil }
        return Double(busy - last.busy) / Double(total - last.total)
    }

    private func gpuUsage() -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }
        var result: Double?
        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            var props: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let dict = props?.takeRetainedValue() as? [String: Any],
               let stats = dict["PerformanceStatistics"] as? [String: Any],
               let util = stats["Device Utilization %"] as? NSNumber {
                result = max(result ?? 0, util.doubleValue / 100)
            }
            IOObjectRelease(entry)
            entry = IOIteratorNext(iterator)
        }
        return result
    }

    /// "Memory Used" as Activity Monitor computes it: app memory + wired + compressed.
    private func memoryUsage() -> (UInt64, UInt64) {
        let total = ProcessInfo.processInfo.physicalMemory
        var vm = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return (0, total) }
        let page = UInt64(vm_kernel_page_size)
        let anonymous = UInt64(vm.internal_page_count), purgeable = UInt64(vm.purgeable_count)
        let app = anonymous > purgeable ? anonymous - purgeable : 0
        let used = (app + UInt64(vm.wire_count) + UInt64(vm.compressor_page_count)) * page
        return (min(used, total), total)
    }

    private func swapUsage() -> (UInt64, UInt64) {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return (0, 0) }
        return (usage.xsu_used, usage.xsu_total)
    }

    private func memoryPressure() -> MemoryPressure {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return .normal }
        switch level {
        case 4...: return .critical
        case 2...: return .warning
        default: return .normal
        }
    }

    /// Total bytes in/out on physical interfaces (en*). Skips loopback and virtual interfaces such as
    /// VPN tunnels and VM bridges, whose traffic would otherwise be counted twice.
    private func networkBytes() -> [String: (bytesIn: UInt64, bytesOut: UInt64)] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &length, nil, 0) == 0, length > 0 else { return [:] }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, UInt32(mib.count), &buffer, &length, nil, 0) == 0 else { return [:] }

        var result: [String: (bytesIn: UInt64, bytesOut: UInt64)] = [:]
        var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
        buffer.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                guard header.ifm_msglen > 0 else { break }
                if Int32(header.ifm_type) == RTM_IFINFO2, offset + MemoryLayout<if_msghdr2>.size <= length {
                    let message = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    if if_indextoname(UInt32(message.ifm_index), &name) != nil {
                        let interface = String(cString: name)
                        if interface.hasPrefix("en") {
                            result[interface] = (message.ifm_data.ifi_ibytes, message.ifm_data.ifi_obytes)
                        }
                    }
                }
                offset += Int(header.ifm_msglen)
            }
        }
        return result
    }

    /// Total bytes read/written across all block storage drivers.
    private func diskIOBytes() -> (UInt64, UInt64) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS else {
            return (0, 0)
        }
        defer { IOObjectRelease(iterator) }
        var read: UInt64 = 0, written: UInt64 = 0
        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            if let stats = IORegistryEntryCreateCFProperty(entry, "Statistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any] {
                read += (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
                written += (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
            }
            IOObjectRelease(entry)
            entry = IOIteratorNext(iterator)
        }
        return (read, written)
    }

    /// Matches Finder: free space includes purgeable data the system can reclaim.
    private func diskUsage() -> (Int64, Int64)? {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity,
              let available = values.volumeAvailableCapacityForImportantUsage else { return nil }
        return (Int64(total) - available, Int64(total))
    }
}
