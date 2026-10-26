import Foundation

public enum DockerParser {
    public static func bytes(_ raw: String) -> UInt64? {
        let text = raw.replacingOccurrences(of: " ", with: "").lowercased()
        guard let unitStart = text.firstIndex(where: { $0.isLetter }),
              let value = Double(text[..<unitStart]), value.isFinite, value >= 0 else { return nil }
        let units: [String: Double] = ["b": 1, "kb": 1e3, "mb": 1e6, "gb": 1e9, "tb": 1e12, "pb": 1e15,
                                       "kib": 1024, "mib": 1_048_576, "gib": 1_073_741_824,
                                       "tib": 1_099_511_627_776, "pib": 1_125_899_906_842_624]
        guard let scale = units[String(text[unitStart...])], value * scale < Double(UInt64.max) else { return nil }
        return UInt64(value * scale)
    }

    public static func date(_ raw: String) -> Date? {
        guard !raw.isEmpty, !raw.hasPrefix("0001-") else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
    }

    public static func rows<T: Decodable>(_ data: Data, as type: T.Type) throws -> [T] {
        guard !data.allSatisfy({ [9, 10, 13, 32].contains($0) }) else { return [] }
        let decoder = JSONDecoder()
        if let array = try? decoder.decode([T].self, from: data) { return array }
        if let value = try? decoder.decode(T.self, from: data) { return [value] }
        do {
            return try data.split(separator: 10).filter { !$0.allSatisfy { [9, 13, 32].contains($0) } }
                .map { try decoder.decode(T.self, from: Data($0)) }
        } catch { throw DockerError.unsupportedOutput }
    }

    public static func stats(_ data: Data) throws -> [String: ContainerMetrics] {
        let values = try rows(data, as: StatsRow.self)
        var result: [String: ContainerMetrics] = [:]
        for row in values {
            let memory = pair(row.MemUsage), network = pair(row.NetIO), block = pair(row.BlockIO)
            let cpu = row.CPUPerc.flatMap { Double($0.replacingOccurrences(of: "%", with: "")) }
            result[row.ID] = ContainerMetrics(
                cpuPercent: cpu.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil },
                memoryBytes: memory.0, memoryLimit: memory.1,
                networkReceived: network.0, networkSent: network.1, blockRead: block.0, blockWritten: block.1
            )
        }
        return result
    }

    private static func pair(_ raw: String?) -> (UInt64?, UInt64?) {
        guard let parts = raw?.components(separatedBy: "/"), parts.count == 2 else { return (nil, nil) }
        return (bytes(parts[0].trimmingCharacters(in: .whitespaces)), bytes(parts[1].trimmingCharacters(in: .whitespaces)))
    }

    public static func containers(_ data: Data) throws -> [DockerContainer] {
        try rows(data, as: InspectRow.self).map { row in
            let bindings = (row.Ports ?? [:]).sorted { $0.key < $1.key }.map { port, hosts in
                let addresses = (hosts ?? []).map { "\($0.HostIp):\($0.HostPort)" }.joined(separator: ", ")
                return addresses.isEmpty ? port : "\(addresses) → \(port)"
            }.joined(separator: " · ")
            return DockerContainer(
                id: row.Id, name: row.Name.hasPrefix("/") ? String(row.Name.dropFirst()) : row.Name,
                image: row.Image, imageID: row.ImageID, state: row.State.Status, health: row.State.Health?.Status,
                startedAtRaw: row.State.StartedAt ?? "", finishedAtRaw: row.State.FinishedAt ?? "",
                labels: row.Labels ?? [:], mounts: row.Mounts ?? [], ports: bindings,
                networks: (row.Networks ?? [:]).keys.sorted()
            )
        }
    }

    public static func storageRows(_ data: Data) throws -> [DockerStorageRow] {
        try rows(data, as: StorageRow.self).map { row in
            DockerStorageRow(kind: row.kind, count: row.TotalCount.value, active: row.Active.value,
                             sizeBytes: bytes(row.Size),
                             reclaimableBytes: bytes(row.Reclaimable.components(separatedBy: " (").first ?? ""))
        }
    }

    public static func images(_ data: Data) throws -> [DockerImage] {
        try rows(data, as: ImageRow.self).map { row in
            DockerImage(id: try DockerImage.canonicalID(row.Id), tags: row.RepoTags ?? [],
                        sizeBytes: row.Size, createdAtRaw: row.Created ?? "")
        }
    }

    private struct StatsRow: Decodable {
        let ID: String
        let CPUPerc: String?
        let MemUsage: String?
        let NetIO: String?
        let BlockIO: String?
    }
    private struct InspectRow: Decodable {
        let Id: String
        let Name: String
        let Image: String
        let ImageID: String?
        let State: StateRow
        let Labels: [String: String]?
        let Mounts: [DockerMount]?
        let Ports: [String: [PortRow]?]?
        let Networks: [String: EmptyObject]?
    }
    private struct StateRow: Decodable {
        let Status: String
        let StartedAt: String?
        let FinishedAt: String?
        let Health: HealthRow?
    }
    private struct HealthRow: Decodable { let Status: String }
    private struct PortRow: Decodable { let HostIp: String; let HostPort: String }
    private struct EmptyObject: Decodable {}
    private struct ImageRow: Decodable {
        let Id: String
        let RepoTags: [String]?
        let Size: UInt64?
        let Created: String?
    }
    private struct StorageRow: Decodable {
        let kind: String
        let TotalCount: FlexibleInt
        let Active: FlexibleInt
        let Size: String
        let Reclaimable: String
        enum CodingKeys: String, CodingKey { case kind = "Type", TotalCount, Active, Size, Reclaimable }
    }
    private struct FlexibleInt: Decodable {
        let value: Int
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let number = try? container.decode(Int.self) { value = number }
            else if let number = Int(try container.decode(String.self)) { value = number }
            else { throw DockerError.unsupportedOutput }
        }
    }
}
