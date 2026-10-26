import XCTest
@testable import MacStatsBarCore

final class DockerImageTests: XCTestCase {
    let firstID = "sha256:" + String(repeating: "a", count: 64)
    let secondID = "sha256:" + String(repeating: "b", count: 64)
    let containerID = String(repeating: "c", count: 64)
    let executable = URL(fileURLWithPath: "/usr/bin/true")

    func testImageInspectHandlesUntaggedAndAliasedImages() throws {
        let raw = imageJSON(id: firstID, tags: "null") + "\n"
            + imageJSON(id: secondID, tags: #"["service:latest","service:v2"]"#)
        let images = try DockerParser.images(Data(raw.utf8))
        XCTAssertEqual(images.count, 2)
        XCTAssertTrue(images[0].isUntagged)
        XCTAssertEqual(images[1].tags, ["service:latest", "service:v2"])
        XCTAssertEqual(images[0].sizeBytes, 52_000_000)
        XCTAssertNotNil(images[0].createdAt)
    }

    func testContainerKeepsActualImageIDSeparateFromOriginalTag() throws {
        let containers = try DockerParser.containers(Data(containerJSON().utf8))
        XCTAssertEqual(containers.first?.image, "service:latest")
        XCTAssertEqual(containers.first?.imageID, secondID)
    }

    func testReferencesUseImageIdentityEvenWhenTagWasMoved() throws {
        let images = [
            DockerImage(id: firstID, tags: ["service:latest"]),
            DockerImage(id: secondID)
        ]
        let containers = [DockerContainer(id: containerID, name: "old-api", image: "service:latest",
                                           imageID: secondID, state: "exited")]
        let linked = try DockerImageInventory.link(images: images, containers: containers)
        XCTAssertTrue(linked[0].containers.isEmpty)
        XCTAssertTrue(linked[1].isUntagged)
        XCTAssertEqual(linked[1].containers.map(\.name), ["old-api"])
        XCTAssertEqual(linked[1].containers.first?.state, "exited")
    }

    func testAllRunningAndStoppedReferencesAreShownOncePerImage() throws {
        let containers = [
            DockerContainer(id: containerID, name: "api", imageID: firstID),
            DockerContainer(id: String(repeating: "d", count: 64), name: "worker", imageID: firstID, state: "exited")
        ]
        let linked = try DockerImageInventory.link(images: [.init(id: firstID)], containers: containers)
        XCTAssertEqual(linked.first?.containers.map(\.name), ["api", "worker"])
    }

    func testMissingImageIdentityCannotBeReportedAsUnreferenced() {
        let container = DockerContainer(id: containerID, name: "unknown", image: "service:latest")
        XCTAssertThrowsError(try DockerImageInventory.link(images: [.init(id: firstID)], containers: [container]))
    }

    func testFullDigestWithoutPrefixIsEquivalentButPartialIDIsRejected() throws {
        let container = DockerContainer(id: containerID, name: "api", imageID: String(firstID.dropFirst(7)))
        let linked = try DockerImageInventory.link(images: [.init(id: firstID)], containers: [container])
        XCTAssertEqual(linked.first?.containers.count, 1)
        let ambiguous = DockerContainer(id: containerID, name: "unknown", imageID: "aaaaaaaaaaaa")
        XCTAssertThrowsError(try DockerImageInventory.link(images: [.init(id: firstID)], containers: [ambiguous]))
    }

    func testInventoryReadsImageAndContainerMetadataWithoutCollectingStats() async throws {
        let host = "unix:///tmp/macstats-test.sock"
        let endpoint = DockerEndpoint(executable: executable, contextName: "local", host: host, daemonID: "daemon-a")
        let ids = "\"\(firstID)\"\n\"\(secondID)\"\n\"\(firstID)\"\n"
        let runner = ScriptedRunner([
            #""daemon-a""#, ids,
            imageJSON(id: firstID, tags: #"["service:latest"]"#) + "\n" + imageJSON(id: secondID, tags: "null"),
            "\"\(containerID)\"\n", containerJSON(), #""daemon-a""#
        ])
        let client = DockerClient(runner: runner, environment: [:], executableURL: executable)
        let inventory = try await client.images(endpoint: endpoint)
        XCTAssertEqual(inventory.endpointIdentity, endpoint.identity)
        XCTAssertEqual(inventory.images.count, 2)
        XCTAssertEqual(inventory.images.first(where: { $0.id == secondID })?.containers.first?.name, "api")
        let requests = await runner.requests
        XCTAssertFalse(requests.contains { $0.arguments.contains("stats") })
        XCTAssertFalse(requests.contains { $0.arguments.contains("prune") || $0.arguments.contains("rm") })
        let inspect = try XCTUnwrap(requests.first { $0.arguments.contains("image") && $0.arguments.contains("inspect") })
        XCTAssertEqual(inspect.arguments.filter { $0 == firstID }.count, 1)
    }

    func testEngineChangeDuringInventoryDiscardsTheResult() async {
        let endpoint = DockerEndpoint(executable: executable, contextName: "local",
                                      host: "unix:///tmp/macstats-test.sock", daemonID: "daemon-a")
        let runner = ScriptedRunner([#""daemon-a""#, "", #""daemon-b""#])
        do {
            _ = try await DockerClient(runner: runner, environment: [:], executableURL: executable).images(endpoint: endpoint)
            XCTFail("Expected engine identity change")
        } catch { XCTAssertEqual(error as? DockerError, .endpointChanged) }
    }

    private func imageJSON(id: String, tags: String) -> String {
        #"{"Id":"\#(id)","RepoTags":\#(tags),"Size":52000000,"Created":"2026-04-16T06:14:39.472107323Z"}"#
    }

    private func containerJSON() -> String {
        #"{"Id":"\#(containerID)","Name":"/api","Image":"service:latest","ImageID":"\#(secondID)","State":{"Status":"exited","StartedAt":"2026-04-16T06:14:39Z","FinishedAt":"2026-10-20T06:00:00Z","Health":null},"Labels":{"com.docker.compose.project":"example"},"Mounts":[],"Ports":{},"Networks":{}}"#
    }
}
