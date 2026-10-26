import XCTest
@testable import MacStatsBarCore

final class DockerIntegrationTests: XCTestCase {
    func testLocalDaemonReadOnly() async throws {
        guard ProcessInfo.processInfo.environment["MACSTATS_DOCKER_READ_ONLY_TESTS"] == "1" else {
            throw XCTSkip("Opt in to read-only tests against a local Docker engine.")
        }
        let client = DockerClient()
        let endpoint = try await client.discover()
        XCTAssertTrue(endpoint.host.hasPrefix("unix:///"))
        let snapshot = try await client.snapshot(endpoint: endpoint)
        XCTAssertEqual(snapshot.endpoint, endpoint)
        XCTAssertEqual(Set(snapshot.containers.map(\.id)).count, snapshot.containers.count)
        let storage = try await client.storage(endpoint: endpoint)
        XCTAssertEqual(storage.endpointIdentity, endpoint.identity)
        XCTAssertFalse(storage.rows.isEmpty)
        let images = try await client.images(endpoint: endpoint)
        XCTAssertEqual(images.endpointIdentity, endpoint.identity)
        XCTAssertEqual(Set(images.images.map(\.id)).count, images.images.count)
        for image in images.images {
            XCTAssertTrue(image.containers.allSatisfy { $0.imageID == image.id })
        }
        let preview = try await client.cleanupPreview(endpoint: endpoint)
        XCTAssertEqual(preview.endpointIdentity, endpoint.identity)
        XCTAssertNotNil(preview.estimatedBytes, "This local engine should provide enough metadata for a filtered preview.")
    }
}
