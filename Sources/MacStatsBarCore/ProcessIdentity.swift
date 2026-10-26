import Darwin
import Foundation

public struct ProcessIdentity: Equatable, Hashable, Sendable {
    public let pid: Int32
    public let ownerUID: UInt32
    public let executable: String
    public let startTime: UInt64
    public var instanceKey: String { "\(pid):\(startTime):\(executable)" }

    public init(pid: Int32, ownerUID: UInt32, executable: String, startTime: UInt64) {
        self.pid = pid; self.ownerUID = ownerUID; self.executable = executable; self.startTime = startTime
    }

    public static func read(pid: Int32) -> ProcessIdentity? {
        guard let result = inspect(pid: pid), !result.identity.executable.isEmpty else { return nil }
        return result.identity
    }

    public static func inspect(pid: Int32) -> (identity: ProcessIdentity, parentPID: Int32)? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let executable = proc_pidpath(pid, &path, UInt32(path.count)) > 0 ? String(cString: path) : ""
        let identity = ProcessIdentity(pid: pid, ownerUID: info.pbi_uid, executable: executable,
                                       startTime: info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec)
        return (identity, Int32(info.pbi_ppid))
    }

    public var isCurrent: Bool { Self.read(pid: pid) == self }
}
