import XCTest
@testable import MacStatsBarCore

final class CleanupEstimateTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let imageID = "sha256:" + String(repeating: "a", count: 64)
    let otherImageID = "sha256:" + String(repeating: "b", count: 64)

    func cache(_ id: String, size: Int64, parents: [String] = [], ageDays: Double = 10,
               shared: Bool = false, inUse: Bool = false, type: String = "regular",
               lastUsed: String? = "auto") throws -> DockerCleanupCache {
        let date = ISO8601DateFormatter().string(from: now.addingTimeInterval(-ageDays * 86400))
        let raw: [String: Any] = [
            "ID": id, "Size": size, " Parents": parents, "InUse": inUse, "Shared": shared,
            "Type": type, "UsageCount": 1,
            "LastUsedAt": lastUsed == nil ? NSNull() : (lastUsed == "auto" ? date : lastUsed!)
        ]
        return try JSONDecoder().decode(DockerCleanupCache.self, from: JSONSerialization.data(withJSONObject: raw))
    }

    func image(_ id: String? = nil, size: Int64 = 1_000, shared: Int64 = 0,
               containers: Int = 0, parent: String = "") throws -> DockerCleanupImage {
        let raw: [String: Any] = ["Id": id ?? imageID, "Size": size, "SharedSize": shared,
                                  "Containers": containers, "ParentId": parent]
        return try JSONDecoder().decode(DockerCleanupImage.self, from: JSONSerialization.data(withJSONObject: raw))
    }

    func estimate(images: [DockerCleanupImage] = [], cache: [DockerCleanupCache] = [],
                  agedIDs: Set<String>? = []) -> DockerCleanupPreview {
        DockerCleanupEstimator.estimate(endpointIdentity: "local", images: images, cache: cache,
                                        ageEligibleImageIDs: agedIDs, daemonTime: now, capturedAt: now)
    }

    func testOldCacheSupportingRecentDescendantsIsNotCounted() throws {
        let records = [
            try cache("base", size: 4_490_000_000),
            try cache("middle", size: 0, parents: ["base"]),
            try cache("recent", size: 7_890_000_000, parents: ["middle"], ageDays: 1)
        ]
        let preview = estimate(cache: records)
        XCTAssertEqual(preview.estimatedBytes, 0, "The old 4.49 GB still supports retained recent cache.")
        XCTAssertEqual(preview.eligibleCacheCount, 0)
        XCTAssertFalse(preview.isPartial)
    }

    func testIndependentOldCacheIsEstimatedWithoutSubtractingReserveTwice() throws {
        let preview = estimate(cache: [
            try cache("recent", size: 4_000_000_000, ageDays: 1),
            try cache("old", size: 1_000_000_000)
        ])
        XCTAssertEqual(preview.estimatedBytes, 1_000_000_000)
        XCTAssertEqual(preview.eligibleCacheCount, 1)
    }

    func testRetentionUsesBinaryReserveAndWholeUnsharedCache() throws {
        let preview = estimate(cache: [try cache("old", size: 3_000_000_000)])
        XCTAssertEqual(preview.estimatedBytes, 3_000_000_000 - 2_147_483_648)
        XCTAssertEqual(estimate(cache: [try cache("small", size: 1_000)]).estimatedBytes, 0)
    }

    func testDefaultPrunePreservesSharedInternalFrontendAndInUseAncestors() throws {
        for protection in ["shared", "internal", "frontend", "inuse"] {
            let preview = estimate(cache: [
                try cache("base", size: 4_000_000_000),
                try cache("protected", size: 4_000_000_000, parents: ["base"],
                          shared: protection == "shared", inUse: protection == "inuse",
                          type: ["internal", "frontend"].contains(protection) ? protection : "regular")
            ])
            XCTAssertEqual(preview.estimatedBytes, 0)
        }
    }

    func testKnownNeverUsedCacheMatchesDaemonAgeRule() throws {
        let preview = estimate(cache: [
            try cache("retained", size: 4_000_000_000, ageDays: 1),
            try cache("never", size: 1_000_000_000, lastUsed: nil)
        ])
        XCTAssertEqual(preview.estimatedBytes, 1_000_000_000)
    }

    func testMalformedCacheMetadataIsUnknownRatherThanAFalseZero() throws {
        let preview = estimate(cache: [try cache("unknown", size: 4_000_000_000, lastUsed: "invalid")])
        XCTAssertTrue(preview.isPartial)
        XCTAssertNil(preview.cacheBytes)
    }

    func testCyclesAndMissingParentsCannotInventIndependentCandidates() throws {
        for records in [
            [try cache("a", size: 4_000_000_000, parents: ["b"]), try cache("b", size: 1, parents: ["a"])],
            [try cache("a", size: 4_000_000_000, parents: ["absent"])]
        ] {
            let preview = estimate(cache: records)
            XCTAssertTrue(preview.isPartial)
            XCTAssertNil(preview.cacheBytes)
        }
    }

    func testImagesUseTheDaemonsAgeFilterInsteadOfConfigCreationTime() throws {
        let preview = estimate(images: [try image()], agedIDs: [])
        XCTAssertEqual(preview.estimatedBytes, 0, "An old config with a recent store timestamp is excluded by the daemon.")
        XCTAssertEqual(preview.eligibleImageCount, 0)
    }

    func testImagesReferencedByStoppedContainersAndTheirParentsAreExcluded() throws {
        let preview = estimate(images: [
            try image(containers: 0),
            try image(otherImageID, containers: 1, parent: imageID)
        ], agedIDs: [imageID, otherImageID])
        XCTAssertEqual(preview.imageBytes, 0)
    }

    func testImageEstimateCountsUniqueBytesAndFlagsUncertainSharing() throws {
        let preview = estimate(images: [try image(size: 5_000, shared: 1_000)], agedIDs: [imageID])
        XCTAssertEqual(preview.imageBytes, 4_000)
        XCTAssertTrue(preview.isPartial, "Shared layers may contribute additional space or remain retained.")
    }

    func testUnavailableAgeFilteringIsNotAssumedToMeanNoWork() throws {
        let preview = estimate(images: [try image()], agedIDs: nil)
        XCTAssertNil(preview.imageBytes)
        XCTAssertTrue(preview.isPartial)
    }

    func testParentsSpellingVariantsParseAndConflictsAreRejected() throws {
        for key in [" Parents", "Parents"] {
            let raw = #"{"ID":"a","Size":1000,"InUse":false,"Shared":false,"Type":"regular","LastUsedAt":null,"KEY":["b"]}"#
                .replacingOccurrences(of: "KEY", with: key)
            let parsed = try JSONDecoder().decode(DockerCleanupCache.self, from: Data(raw.utf8))
            XCTAssertEqual(parsed.parents, ["b"])
        }
        let conflict = #"{"ID":"a"," Parents":["b"],"Parents":["c"]}"#
        XCTAssertThrowsError(try JSONDecoder().decode(DockerCleanupCache.self, from: Data(conflict.utf8)))
    }

    func testPreviewFreshnessRemainsBoundToItsObservationTime() {
        let preview = estimate()
        XCTAssertFalse(preview.needsRefresh(now: now.addingTimeInterval(59)))
        XCTAssertTrue(preview.needsRefresh(now: now.addingTimeInterval(60)))
        XCTAssertTrue(preview.needsRefresh(force: true, now: now))
    }

    func testMissingCacheTypeCannotBeAssumedToBeRegular() throws {
        let raw = #"{"ID":"unknown","Size":4000000000,"Parents":[],"InUse":false,"Shared":false,"LastUsedAt":null}"#
        let record = try JSONDecoder().decode(DockerCleanupCache.self, from: Data(raw.utf8))
        let preview = estimate(cache: [record])
        XCTAssertNil(preview.cacheBytes)
        XCTAssertTrue(preview.isPartial)
    }

    func testMissingImageParentMetadataCannotDiscardProtectionEdges() throws {
        let raw = #"{"Id":"ID","Size":1000,"SharedSize":0,"Containers":1}"#
            .replacingOccurrences(of: "ID", with: otherImageID)
        let child = try JSONDecoder().decode(DockerCleanupImage.self, from: Data(raw.utf8))
        let preview = estimate(images: [try image(), child], agedIDs: [imageID])
        XCTAssertNil(preview.imageBytes)
        XCTAssertTrue(preview.isPartial)
    }

    func testContradictoryImageSnapshotsAreNotAConfidentZero() {
        let preview = estimate(images: [], agedIDs: [imageID])
        XCTAssertNil(preview.imageBytes)
        XCTAssertTrue(preview.isPartial)
        XCTAssertFalse(preview.hasNoEstimatedWork)
    }
}
