import Foundation

public struct DockerCleanupImage: Decodable, Sendable {
    public let id: String
    public let parent: String
    public let parentIsKnown: Bool
    public let size: Int64?
    public let sharedSize: Int64?
    public let containers: Int?

    enum CodingKeys: String, CodingKey { case id = "Id", parent = "ParentId", size = "Size", sharedSize = "SharedSize", containers = "Containers" }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try DockerImage.canonicalID(values.decode(String.self, forKey: .id))
        let rawParent = try values.decodeIfPresent(String.self, forKey: .parent)
        parentIsKnown = values.contains(.parent) && rawParent != nil
        parent = (rawParent ?? "").isEmpty ? "" : try DockerImage.canonicalID(rawParent!)
        size = try values.decodeIfPresent(Int64.self, forKey: .size)
        sharedSize = try values.decodeIfPresent(Int64.self, forKey: .sharedSize)
        containers = try values.decodeIfPresent(Int.self, forKey: .containers)
    }
}

public struct DockerCleanupCache: Decodable, Sendable {
    public let id: String
    public let parents: [String]
    public let size: Int64?
    public let inUse: Bool?
    public let shared: Bool?
    public let type: String
    public let typeIsKnown: Bool
    public let lastUsedAt: Date?
    public let lastUseIsKnown: Bool
    public let usageCount: Int?

    enum CodingKeys: String, CodingKey {
        case id = "ID", parents = "Parents", spacedParents = " Parents", parent = "Parent"
        case size = "Size", inUse = "InUse", shared = "Shared", type = "Type"
        case lastUsedAt = "LastUsedAt", usageCount = "UsageCount"
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        let modern = try values.decodeIfPresent([String].self, forKey: .parents)
        let official = try values.decodeIfPresent([String].self, forKey: .spacedParents)
        if let modern, let official, Set(modern) != Set(official) { throw DockerError.unsupportedOutput }
        let legacy = try values.decodeIfPresent(String.self, forKey: .parent)
        if let legacy, !legacy.isEmpty, let modernParents = modern ?? official,
           !modernParents.contains(legacy) { throw DockerError.unsupportedOutput }
        parents = Array(Set(modern ?? official ?? legacy.map { $0.isEmpty ? [] : [$0] } ?? []))
        size = try values.decodeIfPresent(Int64.self, forKey: .size)
        inUse = try values.decodeIfPresent(Bool.self, forKey: .inUse)
        shared = try values.decodeIfPresent(Bool.self, forKey: .shared)
        let rawType = try values.decodeIfPresent(String.self, forKey: .type)
        typeIsKnown = values.contains(.type) && rawType != nil
        type = (rawType ?? "").isEmpty ? "regular" : rawType!
        let rawDate = try values.decodeIfPresent(String.self, forKey: .lastUsedAt)
        lastUsedAt = rawDate.flatMap(DockerParser.date)
        // A known null means never used. Missing/invalid data must not mean never used.
        lastUseIsKnown = values.contains(.lastUsedAt) && (rawDate == nil || lastUsedAt != nil)
        usageCount = try values.decodeIfPresent(Int.self, forKey: .usageCount)
    }
}

public struct DockerCleanupPreview: Sendable {
    public let endpointIdentity: String
    public let capturedAt: Date
    public let imageBytes: UInt64?
    public let cacheBytes: UInt64?
    public let estimatedBytes: UInt64?
    public let eligibleImageCount: Int
    public let eligibleCacheCount: Int
    public let isPartial: Bool
    public var hasNoEstimatedWork: Bool { estimatedBytes == 0 && !isPartial }

    public func needsRefresh(force: Bool = false, now: Date = Date()) -> Bool {
        force || now < capturedAt || now.timeIntervalSince(capturedAt) >= 60
    }
}

public enum DockerCleanupPolicy {
    public static let imageMinimumAge: TimeInterval = 24 * 3600
    public static let cacheMinimumAge: TimeInterval = 168 * 3600
    // Docker CLI MemBytes parses "2GB" as binary RAM units.
    public static let reservedCacheBytes: UInt64 = 2 * 1024 * 1024 * 1024
    public static let imageAgeFilter = "until=\(Int(imageMinimumAge / 3600))h"
    public static let cacheAgeFilter = "until=\(Int(cacheMinimumAge / 3600))h"
    public static let cacheReserveArgument = "2GB"
}

public enum DockerCleanupEstimator {
    private struct Component {
        var bytes: UInt64?
        var count = 0
        var partial = false
        static var unknown: Component { Component(bytes: nil, partial: true) }
    }

    public static func estimate(endpointIdentity: String, images: [DockerCleanupImage]?,
                                cache: [DockerCleanupCache]?, ageEligibleImageIDs: Set<String>?,
                                daemonTime: Date?, capturedAt: Date = Date(),
                                cacheCleanupSupported: Bool = true) -> DockerCleanupPreview {
        var image = imageEstimate(images, agedIDs: ageEligibleImageIDs)
        let buildCache = cacheCleanupSupported ? cacheEstimate(cache, now: daemonTime) : .unknown
        // SharedSize covers image-to-image sharing, not leases held by retained build cache.
        if image.count > 0, cache?.contains(where: { $0.shared == true }) == true { image.partial = true }
        let known = [image.bytes, buildCache.bytes].compactMap { $0 }
        let total = known.isEmpty ? nil : sum(known)
        return DockerCleanupPreview(endpointIdentity: endpointIdentity, capturedAt: capturedAt,
                                    imageBytes: image.bytes, cacheBytes: buildCache.bytes,
                                    estimatedBytes: total, eligibleImageCount: image.count,
                                    eligibleCacheCount: buildCache.count,
                                    isPartial: image.partial || buildCache.partial || total == nil)
    }

    private static func imageEstimate(_ images: [DockerCleanupImage]?, agedIDs: Set<String>?) -> Component {
        // The daemon's own filter uses the right creation clock for its storage backend.
        if agedIDs?.isEmpty == true { return Component(bytes: 0) }
        guard let images else { return .unknown }
        guard let agedIDs else { return images.isEmpty ? Component(bytes: 0) : .unknown }
        let ids = Set(images.map(\.id))
        guard ids.count == images.count, agedIDs.isSubset(of: ids),
              images.allSatisfy({ ($0.containers ?? -1) >= 0 && $0.parentIsKnown }) else { return .unknown }
        if images.isEmpty { return Component(bytes: 0) }
        let graph = Dictionary(uniqueKeysWithValues: images.map { ($0.id, $0.parent.isEmpty ? [] : [$0.parent]) })
        let seeds = Set(images.filter { ($0.containers ?? -1) > 0 || !agedIDs.contains($0.id) }.map(\.id))
        guard let protected = protectedAncestors(graph, seeds: seeds) else { return .unknown }
        let candidates = images.filter { !protected.contains($0.id) }
        var sizes: [UInt64] = []
        var uncertainSharing = false
        for image in candidates {
            guard let size = image.size, let shared = image.sharedSize,
                  size >= 0, shared >= 0, shared <= size else { return .unknown }
            sizes.append(UInt64(size - shared))
            uncertainSharing = uncertainSharing || shared > 0
        }
        guard let total = sum(sizes) else { return .unknown }
        return Component(bytes: total, count: candidates.count, partial: uncertainSharing)
    }

    private static func cacheEstimate(_ cache: [DockerCleanupCache]?, now: Date?) -> Component {
        guard let cache else { return .unknown }
        if cache.isEmpty { return Component(bytes: 0) }
        guard let now, Set(cache.map(\.id)).count == cache.count,
              cache.allSatisfy({ !$0.id.isEmpty && $0.inUse != nil && $0.shared != nil
                  && ($0.size ?? -1) >= 0 && $0.lastUseIsKnown && $0.typeIsKnown }) else { return .unknown }
        let cutoff = now.addingTimeInterval(-DockerCleanupPolicy.cacheMinimumAge)
        let retained = Set(cache.filter {
            $0.inUse == true || $0.shared == true || ["internal", "frontend"].contains($0.type)
                || $0.lastUsedAt.map { $0 > cutoff } == true
        }.map(\.id))
        let graph = Dictionary(uniqueKeysWithValues: cache.map { ($0.id, $0.parents) })
        // DiskUsage discounts references from unused children. An old InUse=false
        // record may still be required by a recent child: protect its whole ancestry.
        guard let protected = protectedAncestors(graph, seeds: retained) else { return .unknown }
        let candidates = cache.filter { !protected.contains($0.id) }
        guard let candidateBytes = sum(candidates.map { UInt64($0.size!) }),
              let totalUnshared = sum(cache.filter { $0.shared == false }.map { UInt64($0.size!) }) else { return .unknown }
        let budget = totalUnshared > DockerCleanupPolicy.reservedCacheBytes
            ? totalUnshared - DockerCleanupPolicy.reservedCacheBytes : 0
        // The daemon deletes whole leaves and may cross its reserve. Cap this conservative
        // estimate instead of pretending to reproduce exact UsageCount/LRU deletion order.
        return Component(bytes: min(candidateBytes, budget), count: candidates.count,
                         partial: candidateBytes > budget)
    }

    private static func sum(_ values: [UInt64]) -> UInt64? {
        var total: UInt64 = 0
        for value in values {
            let added = total.addingReportingOverflow(value)
            guard !added.overflow else { return nil }
            total = added.partialValue
        }
        return total
    }

    private static func protectedAncestors(_ graph: [String: [String]], seeds: Set<String>) -> Set<String>? {
        var degrees: [String: Int] = [:]
        var children: [String: [String]] = [:]
        for (id, rawParents) in graph {
            let parents = Set(rawParents)
            guard parents.allSatisfy({ graph[$0] != nil }) else { return nil }
            degrees[id] = parents.count
            for parent in parents { children[parent, default: []].append(id) }
        }
        var roots = degrees.filter { $0.value == 0 }.map(\.key)
        var visited = 0
        while let root = roots.popLast() {
            visited += 1
            for child in children[root, default: []] {
                degrees[child]! -= 1
                if degrees[child] == 0 { roots.append(child) }
            }
        }
        guard visited == graph.count else { return nil }
        var protected = seeds
        var pending = Array(seeds)
        while let id = pending.popLast() {
            for parent in graph[id, default: []] where protected.insert(parent).inserted { pending.append(parent) }
        }
        return protected
    }
}
