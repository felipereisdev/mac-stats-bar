import AppKit
import Darwin

/// Usage of one app (all its helper processes summed) or one standalone process.
struct AppUsage: Identifiable {
    let id: String
    let name: String
    /// App bundle path, when this entry is an app (and its helpers).
    var appPath: String?
    var memBytes: UInt64
    var cpuPercent: Double
    var pids: [pid_t]
    /// False for system processes and anything not owned by the current user.
    var canQuit: Bool
}

/// Streams per-process memory and CPU from `top`, which (being setuid) sees every process,
/// including root-owned ones such as WindowServer. Runs only while the menu is open.
final class TopSampler {
    /// Called on the main queue. `cpuValid` is false for top's first sample, whose %CPU is meaningless.
    var onSample: ((_ apps: [AppUsage], _ cpuValid: Bool) -> Void)?

    private var process: Process?
    private var pending = ""
    private var rows: [(pid: pid_t, mem: UInt64, cpu: Double, uid: uid_t, command: String)] = []
    private var expectedRows = 0
    private var inTable = false
    private var sampleIndex = 0
    private var identityCache: [pid_t: Identity] = [:]
    private let currentUID = getuid()
    private let ownBundlePath = Bundle.main.bundlePath

    private struct Identity {
        let key: String
        let name: String
        let appPath: String?
        let isSystem: Bool
    }

    private static let systemPrefixes = ["/System/", "/usr/bin/", "/usr/sbin/", "/usr/libexec/", "/sbin/", "/bin/", "/Library/Apple/"]

    func start() {
        guard process == nil else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/top")
        p.arguments = ["-l", "0", "-s", "2", "-o", "mem", "-stats", "pid,mem,cpu,uid,command"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        pending = ""; rows = []; inTable = false; sampleIndex = 0
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async { self?.consume(text) }
        }
        do {
            try p.run()
            process = p
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
        }
    }

    func stop() {
        guard let p = process else { return }
        (p.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        p.terminate()
        process = nil
    }

    private func consume(_ text: String) {
        guard process != nil else { return }
        pending += text
        while let newline = pending.firstIndex(of: "\n") {
            let line = String(pending[..<newline])
            pending.removeSubrange(...newline)
            handle(line: line)
        }
    }

    private func handle(line: String) {
        if line.hasPrefix("Processes:") {
            if inTable { flush() }
            // "Processes: 706 total, ..." — top prints exactly that many rows.
            expectedRows = Int(line.split(separator: " ").dropFirst().first ?? "") ?? 0
            inTable = false
            return
        }
        if line.hasPrefix("PID") {
            inTable = true
            rows = []
            return
        }
        guard inTable else { return }
        let parts = line.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
        guard parts.count >= 4, let pid = pid_t(parts[0]), let cpu = Double(parts[2]), let uid = uid_t(parts[3]) else { return }
        let command = parts.count > 4 ? parts[4].trimmingCharacters(in: .whitespaces) : ""
        rows.append((pid, Self.parseMemory(parts[1]), cpu, uid, command))
        if rows.count >= expectedRows { flush() }
    }

    private func flush() {
        inTable = false
        let cpuValid = sampleIndex > 0
        sampleIndex += 1

        var groups: [String: AppUsage] = [:]
        var alive = Set<pid_t>()
        for row in rows {
            alive.insert(row.pid)
            let identity = self.identity(for: row.pid, command: row.command)
            var usage = groups[identity.key] ?? AppUsage(
                id: identity.key, name: identity.name, appPath: identity.appPath,
                memBytes: 0, cpuPercent: 0, pids: [],
                canQuit: !identity.isSystem && identity.appPath != ownBundlePath
            )
            // Prefer the installed bundle over a temporary clone for the icon.
            if let path = identity.appPath, usage.appPath?.hasPrefix("/private/var/folders/") ?? true {
                usage.appPath = path
            }
            usage.memBytes += row.mem
            usage.cpuPercent += row.cpu
            usage.pids.append(row.pid)
            if row.uid != currentUID { usage.canQuit = false }
            groups[identity.key] = usage
        }
        identityCache = identityCache.filter { alive.contains($0.key) }
        rows = []
        onSample?(Array(groups.values), cpuValid)
    }

    /// Groups processes by app — the outermost bundle in their path, so helpers count toward their app —
    /// or, outside any bundle, by executable name (so e.g. every `node` shows up as one entry).
    private func identity(for pid: pid_t, command: String) -> Identity {
        if let cached = identityCache[pid] { return cached }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        // Empty when the process already exited; root-owned ones without a path (kernel_task)
        // are still locked by the uid check.
        let path = proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 ? String(cString: buffer) : ""
        let isSystem = Self.systemPrefixes.contains { path.hasPrefix($0) }
        let result: Identity
        // Chrome, for one, runs its main process from a "Google Chrome.app.bundle" clone in /private/var/folders.
        if let range = path.range(of: #"\.app(\.bundle)?/"#, options: .regularExpression) {
            let bundlePath = String(path[..<range.upperBound].dropLast())
            let name = bundlePath.hasSuffix(".app.bundle")
                ? String((bundlePath as NSString).lastPathComponent.dropLast(".app.bundle".count))
                : FileManager.default.displayName(atPath: bundlePath)
            result = Identity(key: "app:" + name, name: name, appPath: bundlePath, isSystem: isSystem)
        } else {
            let name = path.isEmpty ? command : (path as NSString).lastPathComponent
            result = Identity(key: "proc:" + name, name: name, appPath: nil, isSystem: isSystem)
        }
        identityCache[pid] = result
        return result
    }

    /// Parses top's MEM column, e.g. "6549M+", "16G", "980K-".
    static func parseMemory<S: StringProtocol>(_ raw: S) -> UInt64 {
        let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: "+-"))
        guard let unit = trimmed.last else { return 0 }
        let multipliers: [Character: Double] = ["B": 1, "K": 0x1p10, "M": 0x1p20, "G": 0x1p30, "T": 0x1p40]
        if let m = multipliers[unit], let value = Double(trimmed.dropLast()) {
            return UInt64(value * m)
        }
        return UInt64(trimmed) ?? 0
    }
}
