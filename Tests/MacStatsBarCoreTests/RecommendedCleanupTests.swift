import XCTest
@testable import MacStatsBarCore

final class RecommendedCleanupTests: XCTestCase {
    private let endpoint = DockerEndpoint(executable: URL(fileURLWithPath: "/usr/bin/true"),
                                          contextName: "local", host: "unix:///tmp/macstats-test.sock", daemonID: "daemon-a")

    private func storage(images: String = "24.7GB", cache: String = "1.52GB",
                         capturedAt: Date = Date()) throws -> DockerStorage {
        let raw = """
        {"Type":"Images","TotalCount":72,"Active":30,"Size":"45.15GB","Reclaimable":"\(images)"}
        {"Type":"Build Cache","TotalCount":141,"Active":0,"Size":"16.61GB","Reclaimable":"\(cache)"}
        {"Type":"Containers","TotalCount":32,"Active":7,"Size":"1.97GB","Reclaimable":"1.92GB"}
        {"Type":"Local Volumes","TotalCount":45,"Active":25,"Size":"24.11GB","Reclaimable":"20GB"}
        """
        return DockerStorage(endpointIdentity: endpoint.identity, capturedAt: capturedAt,
                             rows: try DockerParser.storageRows(Data(raw.utf8)))
    }

    func testRecommendedCleanupPreservesContainersVolumesAndNetworks() throws {
        let plan = try DockerPrune.makeRecommendedPlan(endpoint: endpoint, storage: storage())
        XCTAssertTrue(plan.isRecommended)
        XCTAssertEqual(Set(plan.categories), [.unusedImages, .buildCache])
        let commands = plan.categories.map(\.arguments)
        XCTAssertFalse(commands.flatMap { $0 }.contains { ["container", "volume", "network", "system", "rm", "stop"].contains($0) })
        XCTAssertEqual(PruneCategory.unusedImages.arguments,
                       ["image", "prune", "--all", "--force", "--filter", "until=24h"])
    }

    func testRecommendedCleanupDoesNotAdvertiseUnfilteredTotals() throws {
        let plan = try DockerPrune.makeRecommendedPlan(endpoint: endpoint, storage: storage())
        XCTAssertNil(plan.estimatedUpperBoundBytes, "Docker's totals precede our age, cache retention and dependency rules.")
        let afterCleanup = try DockerPrune.makeRecommendedPlan(
            endpoint: endpoint, storage: storage(images: "206.9MB", cache: "12.27GB"))
        XCTAssertNil(afterCleanup.estimatedUpperBoundBytes, "Remaining raw totals are not a second cleanup prediction.")
    }

    func testUnknownCacheDoesNotProduceAnIncompleteUpperBound() throws {
        let plan = try DockerPrune.makeRecommendedPlan(endpoint: endpoint, storage: storage(cache: "N/A"))
        XCTAssertNil(plan.estimatedUpperBoundBytes)
    }

    func testRecommendedCleanupDoesNotInventAPreviewEvenFromZeroTotals() throws {
        let plan = try DockerPrune.makeRecommendedPlan(endpoint: endpoint, storage: storage(images: "0B", cache: "0B"))
        XCTAssertNil(plan.estimatedUpperBoundBytes, "Unknown recovery is not a confirmed zero-byte cleanup.")
    }

    func testRecommendedPlanRequiresFreshDataFromTheDisplayedEngine() throws {
        let old = try storage(capturedAt: Date().addingTimeInterval(-61))
        XCTAssertThrowsError(try DockerPrune.makeRecommendedPlan(endpoint: endpoint, storage: old))
        let foreign = DockerStorage(endpointIdentity: "other", rows: [])
        XCTAssertThrowsError(try DockerPrune.makeRecommendedPlan(endpoint: endpoint, storage: foreign))
    }

    func testRecommendedExecutionUsesDaemonPruneProtectionAndBoundedLocalCache() async throws {
        let plan = try DockerPrune.makeRecommendedPlan(endpoint: endpoint, storage: storage())
        let discovery = ["local\n", #""unix:///tmp/macstats-test.sock""#, #""daemon-a""#]
        let runner = ScriptedRunner(discovery + ["Total reclaimed space: 3MB\n"] + discovery
                                    + ["Usage: docker builder prune\n--keep-storage\n", "Total: 2MB\n"])
        let client = DockerClient(runner: runner, environment: ["BUILDX_BUILDER": "elsewhere"], executableURL: endpoint.executable)
        let report = await client.execute(plan)
        XCTAssertEqual(report.outcome, .reclaimed(5_000_000))
        let requests = await runner.requests
        let mutations = requests.filter { $0.arguments.contains("prune") && !$0.arguments.contains("--help") }
        XCTAssertEqual(mutations.count, 2)
        XCTAssertTrue(mutations.allSatisfy { Array($0.arguments.prefix(2)) == ["--host", endpoint.host] })
        XCTAssertTrue(mutations[0].arguments.contains("--all"))
        XCTAssertEqual(mutations[1].environment["DOCKER_BUILDKIT"], "0")
        XCTAssertFalse(mutations.contains { $0.arguments.contains("container") || $0.arguments.contains("network") })
    }
}
