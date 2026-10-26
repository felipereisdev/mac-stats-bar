import XCTest
@testable import MacStatsBarCore

final class CleanupPreviewClientTests: XCTestCase {
    let endpoint = DockerEndpoint(executable: URL(fileURLWithPath: "/usr/bin/true"),
                                   contextName: "local", host: "unix:///tmp/macstats-estimate.sock", daemonID: "daemon-a")
    let images = #"[]"#
    let cache = #"{"BuildCache":[]}"#
    let help = "Usage: docker builder prune\n--keep-storage\n"

    func testPreviewOnlyReadsPinnedLocalEngineAndMatchesCleanupAgeFilter() async throws {
        let runner = ScriptedRunner([#""daemon-a""#, #""2033-05-18T03:33:20Z""#, images, cache, "", help, #""daemon-a""#])
        let client = DockerClient(runner: runner, environment: [:], executableURL: endpoint.executable)
        let preview = try await client.cleanupPreview(endpoint: endpoint)
        XCTAssertEqual(preview.endpointIdentity, endpoint.identity)
        XCTAssertEqual(preview.estimatedBytes, 0)
        XCTAssertFalse(preview.isPartial)
        let requests = await runner.requests
        let http = requests.filter { $0.executable.path == "/usr/bin/curl" }
        XCTAssertEqual(http.count, 2)
        XCTAssertTrue(http.allSatisfy { $0.arguments.contains("--unix-socket") && $0.arguments.contains("/tmp/macstats-estimate.sock") })
        XCTAssertTrue(http.allSatisfy { $0.arguments.contains("GET") && $0.arguments.contains("--noproxy") })
        XCTAssertTrue(http.allSatisfy { $0.arguments.first == "--disable" }, "Local curl configuration cannot alter this read-only transport.")
        XCTAssertTrue(requests.contains { $0.arguments.contains("image") && $0.arguments.contains(DockerCleanupPolicy.imageAgeFilter) })
        XCTAssertFalse(requests.contains { $0.arguments.contains("prune") && !$0.arguments.contains("--help") })
    }

    func testUnsupportedAgeFilterDoesNotInventAnImageEstimate() async throws {
        let rawImages = #"[{"Id":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","ParentId":"","Size":1000,"SharedSize":0,"Containers":0}]"#
        let outputs = [#""daemon-a""#, #""2033-05-18T03:33:20Z""#, rawImages, cache]
        let runner = ScriptedRunner(results: outputs.map { .init(stdout: Data($0.utf8)) } +
            [.init(stderr: Data("invalid filter until".utf8), exitCode: 1)] +
            [help, #""daemon-a""#].map { .init(stdout: Data($0.utf8)) })
        let preview = try await DockerClient(runner: runner, environment: [:], executableURL: endpoint.executable)
            .cleanupPreview(endpoint: endpoint)
        XCTAssertNil(preview.imageBytes)
        XCTAssertTrue(preview.isPartial)
    }

    func testDaemonChangeDiscardsTheAnalysis() async {
        let runner = ScriptedRunner([#""daemon-a""#, #""2033-05-18T03:33:20Z""#, images, cache, "", help, #""daemon-b""#])
        do {
            _ = try await DockerClient(runner: runner, environment: [:], executableURL: endpoint.executable).cleanupPreview(endpoint: endpoint)
            XCTFail("Expected daemon identity change")
        } catch { XCTAssertEqual(error as? DockerError, .endpointChanged) }
    }

    func testRemoteContextIsRejectedBeforeAnyTransportCall() async {
        let remote = DockerEndpoint(executable: endpoint.executable, contextName: "remote", host: "tcp://example.invalid:2375", daemonID: "daemon-a")
        let runner = ScriptedRunner([])
        do {
            _ = try await DockerClient(runner: runner, environment: [:], executableURL: endpoint.executable).cleanupPreview(endpoint: remote)
            XCTFail("Expected remote context rejection")
        } catch { XCTAssertEqual(error as? DockerError, .remoteContext) }
        let requests = await runner.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testUnreadableMetadataIsUnknownAndNeverFallsBackToAggregateTotals() async throws {
        let runner = ScriptedRunner([#""daemon-a""#, #""2033-05-18T03:33:20Z""#,
                                     "unsupported image payload", "unsupported cache payload",
                                     #""sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa""#,
                                     help, #""daemon-a""#])
        let preview = try await DockerClient(runner: runner, environment: [:], executableURL: endpoint.executable).cleanupPreview(endpoint: endpoint)
        XCTAssertNil(preview.estimatedBytes)
        XCTAssertTrue(preview.isPartial)
        XCTAssertFalse(preview.hasNoEstimatedWork)
    }
}
