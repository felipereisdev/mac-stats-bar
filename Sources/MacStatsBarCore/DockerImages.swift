import Foundation

public struct DockerImage: Sendable, Identifiable, Equatable {
    public let id: String
    public let tags: [String]
    public let sizeBytes: UInt64?
    public let createdAtRaw: String
    public var containers: [DockerContainer]
    public var isUntagged: Bool { tags.isEmpty }
    public var createdAt: Date? { DockerParser.date(createdAtRaw) }
    public var shortID: String { String(id.replacingOccurrences(of: "sha256:", with: "").prefix(12)) }

    public init(id: String, tags: [String] = [], sizeBytes: UInt64? = nil,
                createdAtRaw: String = "", containers: [DockerContainer] = []) {
        self.id = id
        self.tags = Array(Set(tags.filter { !$0.isEmpty && $0 != "<none>:<none>" && $0 != "<none>" })).sorted()
        self.sizeBytes = sizeBytes; self.createdAtRaw = createdAtRaw; self.containers = containers
    }

    static func canonicalID(_ raw: String) throws -> String {
        let digest = raw.hasPrefix("sha256:") ? String(raw.dropFirst(7)) : raw
        guard digest.count == 64,
              digest.allSatisfy({ $0.isASCII && ($0.isNumber || ("a"..."f").contains(String($0))) }) else {
            throw DockerError.unsupportedOutput
        }
        return "sha256:" + digest
    }
}

public struct DockerImageInventory: Sendable {
    public let endpointIdentity: String
    public let capturedAt: Date
    public let images: [DockerImage]

    public init(endpointIdentity: String, capturedAt: Date = Date(), images: [DockerImage]) {
        self.endpointIdentity = endpointIdentity; self.capturedAt = capturedAt; self.images = images
    }

    public func needsRefresh(force: Bool = false, now: Date = Date()) -> Bool {
        force || now < capturedAt || now.timeIntervalSince(capturedAt) >= 60
    }

    public static func link(images: [DockerImage], containers: [DockerContainer]) throws -> [DockerImage] {
        var references: [String: [DockerContainer]] = [:]
        // Config.Image can name a tag that has since moved. Only immutable IDs establish a reference.
        for container in containers {
            guard let raw = container.imageID else { throw DockerError.unsupportedOutput }
            let id = try DockerImage.canonicalID(raw)
            references[id, default: []].append(container)
        }
        return try images.map { image in
            var result = image
            result.containers = references[try DockerImage.canonicalID(image.id), default: []].sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            return result
        }
    }
}
