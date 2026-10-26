import Foundation

public enum PruneCategory: String, CaseIterable, Sendable, Hashable, Identifiable {
    case danglingImages, unusedImages, buildCache, stoppedContainers, unusedNetworks
    public var id: String { rawValue }
    public var arguments: [String] {
        switch self {
        case .danglingImages: ["image", "prune", "--force", "--filter", "until=24h"]
        // Docker retains images referenced by ANY container, including stopped containers.
        case .unusedImages: ["image", "prune", "--all", "--force", "--filter", DockerCleanupPolicy.imageAgeFilter]
        case .buildCache: ["builder", "prune", "--force", "--filter", DockerCleanupPolicy.cacheAgeFilter,
                          "--keep-storage", DockerCleanupPolicy.cacheReserveArgument]
        case .stoppedContainers: ["container", "prune", "--force", "--filter", "until=24h"]
        case .unusedNetworks: ["network", "prune", "--force", "--filter", "until=24h"]
        }
    }
}

public struct PrunePlan: Sendable {
    public let endpoint: DockerEndpoint
    public let categories: [PruneCategory]
    public let expiresAt: Date
    public let estimatedUpperBoundBytes: UInt64?
    public var isRecommended: Bool { Set(categories) == DockerPrune.recommendedSelection }
}

public enum DockerPrune {
    public static let recommendedSelection: Set<PruneCategory> = [.unusedImages, .buildCache]

    public static func makeRecommendedPlan(endpoint: DockerEndpoint, storage: DockerStorage,
                                            now: Date = Date()) throws -> PrunePlan {
        try makePlan(selection: recommendedSelection, endpoint: endpoint, storage: storage, now: now)
    }

    public static func makePlan(selection: Set<PruneCategory>, endpoint: DockerEndpoint,
                                storage: DockerStorage, now: Date = Date()) throws -> PrunePlan {
        guard !selection.isEmpty else { throw DockerError.emptySelection }
        guard storage.endpointIdentity == endpoint.identity else { throw DockerError.endpointChanged }
        guard now >= storage.capturedAt, now.timeIntervalSince(storage.capturedAt) < 60 else { throw DockerError.stalePlan }
        let kinds: [PruneCategory: String] = [.danglingImages: "Images", .unusedImages: "Images",
                                             .buildCache: "Build Cache", .stoppedContainers: "Containers"]
        let expectedKinds = Set(selection.compactMap { kinds[$0] })
        let completeEstimate = expectedKinds.allSatisfy { kind in
            storage.rows.first(where: { $0.kind == kind })?.reclaimableBytes != nil
        }
        let values = storage.rows.filter { row in selection.contains { kinds[$0] == row.kind } }.compactMap(\.reclaimableBytes)
        let estimate = values.reduce(UInt64(0)) { current, value in
            let sum = current.addingReportingOverflow(value)
            return sum.overflow ? UInt64.max : sum.partialValue
        }
        // system df has no preview for these prune operations: age, cache retention,
        // dependencies and shared layers are resolved by the daemon during cleanup.
        // Its aggregate totals must not be advertised as this action's recovery estimate.
        let unmeasurableScope = !selection.isDisjoint(with: [.danglingImages, .unusedImages, .buildCache])
        return PrunePlan(endpoint: endpoint, categories: PruneCategory.allCases.filter(selection.contains),
                         expiresAt: storage.capturedAt.addingTimeInterval(60),
                         estimatedUpperBoundBytes: unmeasurableScope || values.isEmpty || !completeEstimate ? nil : estimate)
    }
}

public struct PruneCategoryResult: Sendable, Identifiable {
    public var id: PruneCategory { category }
    public let category: PruneCategory
    public let output: String
    public let error: String?
    public let isInconclusive: Bool
    public var succeeded: Bool { error == nil && !isInconclusive }

    public var reclaimedBytes: UInt64? {
        guard succeeded else { return nil }
        for line in output.components(separatedBy: .newlines).reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            for prefix in ["Total reclaimed space:", "Total:"] where trimmed.hasPrefix(prefix) {
                return DockerParser.bytes(String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces))
            }
        }
        return nil
    }
}

public enum PruneOutcome: Equatable, Sendable {
    case noSpaceReclaimed
    case reclaimed(UInt64)
    case completedWithoutMeasurement
    case failed
}

public struct PruneReport: Sendable {
    public let results: [PruneCategoryResult]
    public var succeeded: Bool { !results.isEmpty && results.allSatisfy(\.succeeded) }
    public var outcome: PruneOutcome {
        guard succeeded else { return .failed }
        var total: UInt64 = 0
        for result in results {
            guard let bytes = result.reclaimedBytes else { return .completedWithoutMeasurement }
            let sum = total.addingReportingOverflow(bytes)
            guard !sum.overflow else { return .completedWithoutMeasurement }
            total = sum.partialValue
        }
        return total == 0 ? .noSpaceReclaimed : .reclaimed(total)
    }
}
