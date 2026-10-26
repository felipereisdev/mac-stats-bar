import XCTest
@testable import MacStatsBarCore

actor ScriptedRunner: CommandRunning {
    var requests: [CommandRequest] = []
    var responses: [CommandResult]
    init(_ outputs: [String]) { responses = outputs.map { CommandResult(stdout: Data($0.utf8)) } }
    init(results: [CommandResult]) { responses = results }
    func run(_ request: CommandRequest) async throws -> CommandResult {
        requests.append(request)
        guard !responses.isEmpty else { throw DockerError.unsupportedOutput }
        return responses.removeFirst()
    }
}

final class StepClock: @unchecked Sendable {
    private let lock = NSLock()
    private var dates: [Date]
    init(_ dates: [Date]) { self.dates = dates }
    func now() -> Date {
        lock.lock(); defer { lock.unlock() }
        if dates.count > 1 { return dates.removeFirst() }
        return dates[0]
    }
}

actor ThrowingPruneRunner: CommandRunning {
    var requests: [CommandRequest] = []
    var outputs = ["local\n", #""unix:///tmp/macstats-test.sock""#, #""daemon-a""#]
    func run(_ request: CommandRequest) async throws -> CommandResult {
        requests.append(request)
        if request.arguments.contains("prune") { throw CommandFailure.outputLimitExceeded }
        guard !outputs.isEmpty else { throw DockerError.unsupportedOutput }
        return CommandResult(stdout: Data(outputs.removeFirst().utf8))
    }
}

final class DockerTests: XCTestCase {
    let executable = URL(fileURLWithPath: "/usr/bin/true")
    let host = "unix:///tmp/macstats-test.sock"
    let containerID = String(repeating: "a", count: 64)

    func endpoint(_ daemon: String = "daemon-a") -> DockerEndpoint {
        DockerEndpoint(executable: executable, contextName: "local", host: host, daemonID: daemon)
    }

    func testByteParserSupportsDecimalAndBinaryAndRejectsUnavailable() {
        XCTAssertEqual(DockerParser.bytes("1.5GiB"), 1_610_612_736)
        XCTAssertEqual(DockerParser.bytes("2 MB"), 2_000_000)
        XCTAssertEqual(DockerParser.bytes("512KiB"), 524_288)
        XCTAssertEqual(DockerParser.bytes("0B"), 0)
        XCTAssertNil(DockerParser.bytes("N/A"))
        XCTAssertNil(DockerParser.bytes("-1GB"))
        XCTAssertNil(DockerParser.bytes("NaNGiB"))
        XCTAssertNil(DockerParser.bytes("1e99GB"))
    }

    func testStatsPreservesMissingValuesAndCumulativeCounters() throws {
        let rows = try DockerParser.stats(Data(#"""
        {"ID":"aaa","CPUPerc":"0.03%","MemUsage":"2MiB / 1GiB","NetIO":"1kB / 2kB","BlockIO":"3kB / 4kB"}
        {"ID":"bbb","CPUPerc":"N/A","MemUsage":"N/A","NetIO":"N/A","BlockIO":"N/A"}
        """#.utf8))
        XCTAssertEqual(rows["aaa"]?.cpuPercent, 0.03)
        XCTAssertEqual(rows["aaa"]?.memoryBytes, 2_097_152)
        XCTAssertEqual(rows["aaa"]?.networkReceived, 1000)
        XCTAssertNil(rows["bbb"]?.cpuPercent)
        XCTAssertNil(rows["bbb"]?.memoryBytes)
        XCTAssertNil(rows["bbb"]?.networkReceived)
    }

    func testInspectDecodesComposeHealthMountsPortsAndFinishedTime() throws {
        let containers = try DockerParser.containers(Data(inspectFixture().utf8))
        let app = try XCTUnwrap(containers.first)
        XCTAssertEqual(app.id, containerID)
        XCTAssertEqual(app.name, "api")
        XCTAssertEqual(app.project, "example")
        XCTAssertEqual(app.health, "healthy")
        XCTAssertTrue(app.hasPersistentMounts)
        XCTAssertTrue(app.ports.contains("8080"))
        XCTAssertEqual(app.networks, ["example_default"])
        XCTAssertNotNil(app.startedAt)
        XCTAssertNil(app.finishedAt)
    }

    func testStorageUsesReclaimableRatherThanSummingImageLayers() throws {
        let rows = try DockerParser.storageRows(Data(#"""
        {"Type":"Images","TotalCount":"5","Active":"2","Size":"10GB","Reclaimable":"3GB (30%)"}
        {"Type":"Local Volumes","TotalCount":2,"Active":1,"Size":"2GB","Reclaimable":"1GB (50%)"}
        """#.utf8))
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].reclaimableBytes, 3_000_000_000)
        XCTAssertEqual(rows[1].count, 2)
    }

    func testMalformedJSONIsAnErrorRatherThanEmptyInventory() {
        XCTAssertThrowsError(try DockerParser.containers(Data("not-json".utf8)))
        XCTAssertThrowsError(try DockerParser.stats(Data("not-json".utf8)))
    }

    func testRemoteHostIsRejectedBeforeAnyDaemonRequest() async {
        let runner = ScriptedRunner([])
        let client = DockerClient(runner: runner, environment: ["DOCKER_HOST": "ssh://production"], executableURL: executable)
        do { _ = try await client.discover(); XCTFail("Expected rejection") }
        catch { XCTAssertEqual(error as? DockerError, .remoteContext) }
        let count = await runner.requests.count
        XCTAssertEqual(count, 0)
    }

    func testContextOverrideWinsOverHostAndEnvironmentIsSanitized() async throws {
        let runner = ScriptedRunner([#""unix:///tmp/macstats-test.sock""#, #""daemon-a""#])
        let client = DockerClient(runner: runner, environment: [
            "DOCKER_CONTEXT": "local", "DOCKER_HOST": "ssh://production",
            "DOCKER_TLS_VERIFY": "1", "DOCKER_CONFIG": "/tmp/macstats-config"
        ], executableURL: executable)
        let found = try await client.discover()
        XCTAssertEqual(found.host, host)
        let requests = await runner.requests
        XCTAssertEqual(requests[0].arguments.prefix(3), ["context", "inspect", "local"])
        XCTAssertEqual(requests[1].arguments.prefix(2), ["--host", host])
        XCTAssertNil(requests[1].environment["DOCKER_HOST"])
        XCTAssertNil(requests[1].environment["DOCKER_CONTEXT"])
        XCTAssertNil(requests[1].environment["DOCKER_TLS_VERIFY"])
        XCTAssertEqual(requests[1].environment["DOCKER_CONFIG"], "/tmp/macstats-config")
    }

    func testRemoteContextIsRejectedAfterInspectBeforeInfo() async {
        let runner = ScriptedRunner(["production\n", #""tcp://remote:2376""#])
        let client = DockerClient(runner: runner, environment: [:], executableURL: executable)
        do { _ = try await client.discover(); XCTFail("Expected rejection") }
        catch { XCTAssertEqual(error as? DockerError, .remoteContext) }
        let requests = await runner.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertFalse(requests.contains { $0.arguments.contains("info") })
    }

    func testMissingCLIHasSpecificError() async {
        let client = DockerClient(environment: ["PATH": ""], configuredPath: "/does/not/exist")
        do { _ = try await client.discover(); XCTFail("Expected missing CLI") }
        catch { XCTAssertEqual(error as? DockerError, .cliMissing) }
    }

    func testEmptyDaemonIsValidSnapshotWithoutStatsRequest() async throws {
        let runner = ScriptedRunner([#""daemon-a""#, ""])
        let client = DockerClient(runner: runner, environment: [:], executableURL: executable)
        let snapshot = try await client.snapshot(endpoint: endpoint())
        XCTAssertTrue(snapshot.containers.isEmpty)
        let requests = await runner.requests
        XCTAssertFalse(requests.contains { $0.arguments.contains("stats") })
    }

    func testDaemonChangePreventsReadingOrMutatingOldResource() async {
        let runner = ScriptedRunner([#""daemon-b""#])
        let client = DockerClient(runner: runner, environment: [:], executableURL: executable)
        do { _ = try await client.snapshot(endpoint: endpoint()); XCTFail("Expected daemon change") }
        catch { XCTAssertEqual(error as? DockerError, .endpointChanged) }
    }

    func testPruneRequiresSelectionAndFreshStorage() throws {
        let now = Date()
        let storage = DockerStorage(endpointIdentity: endpoint().identity, capturedAt: now, rows: [])
        XCTAssertThrowsError(try DockerPrune.makePlan(selection: [], endpoint: endpoint(), storage: storage, now: now))
        XCTAssertThrowsError(try DockerPrune.makePlan(
            selection: [.danglingImages], endpoint: endpoint(), storage: storage, now: now.addingTimeInterval(61)
        ))
        XCTAssertThrowsError(try DockerPrune.makePlan(
            selection: [.danglingImages], endpoint: endpoint("other"), storage: storage, now: now
        ))
    }

    func testDanglingCleanupDoesNotClaimAllUnusedImageSpace() throws {
        let now = Date()
        let rows = try DockerParser.storageRows(Data(#"""
        {"Type":"Images","TotalCount":"72","Active":"30","Size":"45.15GB","Reclaimable":"24.7GB (54%)"}
        {"Type":"Build Cache","TotalCount":"141","Active":"0","Size":"16.61GB","Reclaimable":"1.52GB (9%)"}
        """#.utf8))
        let storage = DockerStorage(endpointIdentity: endpoint().identity, capturedAt: now, rows: rows)
        let imagesOnly = try DockerPrune.makePlan(selection: [.danglingImages], endpoint: endpoint(), storage: storage, now: now)
        XCTAssertNil(imagesOnly.estimatedUpperBoundBytes, "The daemon total includes tagged images outside dangling cleanup.")
        let mixed = try DockerPrune.makePlan(selection: [.danglingImages, .buildCache], endpoint: endpoint(), storage: storage, now: now)
        XCTAssertNil(mixed.estimatedUpperBoundBytes, "Do not show a misleading combined bound for mismatched image scope.")
    }

    func testPruneNeverAddsVolumesAndOnlyUnusedImagesUsesAll() {
        let operations = PruneCategory.allCases.map(\.arguments)
        XCTAssertEqual(operations.count, 5)
        XCTAssertFalse(operations.flatMap { $0 }.contains("--volumes"))
        XCTAssertEqual(PruneCategory.allCases.filter { $0.arguments.contains("--all") }, [.unusedImages])
        XCTAssertFalse(operations.flatMap { $0 }.contains("system"))
        XCTAssertTrue(PruneCategory.buildCache.arguments.contains("until=168h"))
        XCTAssertTrue(PruneCategory.buildCache.arguments.contains("--keep-storage"))
        XCTAssertTrue(PruneCategory.stoppedContainers.arguments.contains("until=24h"))
    }

    func testExpiredPlanNeverRunsCommands() async throws {
        let old = Date().addingTimeInterval(-120)
        let storage = DockerStorage(endpointIdentity: endpoint().identity, capturedAt: old, rows: [])
        let plan = try DockerPrune.makePlan(selection: [.danglingImages], endpoint: endpoint(), storage: storage, now: old)
        let runner = ScriptedRunner([])
        let report = await DockerClient(runner: runner, environment: [:], executableURL: executable).execute(plan)
        XCTAssertFalse(report.succeeded)
        let count = await runner.requests.count
        XCTAssertEqual(count, 0)
    }

    func testPruneReportsPartialFailureWithoutRetrying() async throws {
        let now = Date()
        let storage = DockerStorage(endpointIdentity: endpoint().identity, capturedAt: now, rows: [])
        let plan = try DockerPrune.makePlan(selection: [.danglingImages, .buildCache], endpoint: endpoint(), storage: storage, now: now)
        // Each category revalidates the currently selected local endpoint and daemon.
        let discovery = ["local\n", #""unix:///tmp/macstats-test.sock""#, #""daemon-a""#]
        let runner = ScriptedRunner(results:
            discovery.map { CommandResult(stdout: Data($0.utf8)) } +
            [CommandResult(stdout: Data("Total reclaimed space: 3MB\n".utf8))] +
            discovery.map { CommandResult(stdout: Data($0.utf8)) } +
            [CommandResult(stdout: Data("Usage:  docker builder prune\n--keep-storage\n".utf8))] +
            [CommandResult(stderr: Data("build cache is busy".utf8), exitCode: 1)]
        )
        let report = await DockerClient(runner: runner, environment: [:], executableURL: executable).execute(plan)
        XCTAssertEqual(report.results.count, 2)
        XCTAssertTrue(report.results[0].succeeded)
        XCTAssertFalse(report.results[1].succeeded)
        XCTAssertFalse(report.succeeded)
        let requests = await runner.requests
        XCTAssertEqual(requests.filter { $0.arguments.contains("prune") && !$0.arguments.contains("--help") }.count, 2)
    }

    func testChangedContainerCannotBeStoppedAfterReview() async {
        let original = try! DockerParser.containers(Data(inspectFixture().utf8))[0]
        let changed = inspectFixture().replacingOccurrences(of: "2026-10-20T08:00:00", with: "2026-10-26T09:00:00")
        let runner = ScriptedRunner(["local\n", #""unix:///tmp/macstats-test.sock""#, #""daemon-a""#, changed])
        let client = DockerClient(runner: runner, environment: [:], executableURL: executable)
        do {
            try await client.changeState(container: original, action: .stop, endpoint: endpoint())
            XCTFail("Expected stale resource rejection")
        } catch { XCTAssertEqual(error as? DockerError, .resourceChanged) }
        let requests = await runner.requests
        XCTAssertFalse(requests.contains { $0.arguments.contains("stop") })
    }

    func testStopUsesFullIDAndChecksTheResultingState() async throws {
        let original = try DockerParser.containers(Data(inspectFixture().utf8))[0]
        let stopped = inspectFixture().replacingOccurrences(of: #""Status":"running""#, with: #""Status":"exited""#)
        let runner = ScriptedRunner(["local\n", #""unix:///tmp/macstats-test.sock""#, #""daemon-a""#, inspectFixture(), containerID, stopped])
        let client = DockerClient(runner: runner, environment: [:], executableURL: executable)
        try await client.changeState(container: original, action: .stop, endpoint: endpoint())
        let requests = await runner.requests
        let stop = try XCTUnwrap(requests.first { $0.arguments.contains("stop") })
        XCTAssertEqual(stop.arguments, ["--host", host, "container", "stop", "--time", "30", containerID])
        XCTAssertTrue(requests.last!.arguments.contains("inspect"))
    }

    func testFailedStopVerificationIsNotReportedAsSuccess() async throws {
        let original = try DockerParser.containers(Data(inspectFixture().utf8))[0]
        let runner = ScriptedRunner(["local\n", #""unix:///tmp/macstats-test.sock""#, #""daemon-a""#, inspectFixture(), containerID, inspectFixture()])
        let client = DockerClient(runner: runner, environment: [:], executableURL: executable)
        do { try await client.changeState(container: original, action: .stop, endpoint: endpoint()); XCTFail("Expected state mismatch") }
        catch { XCTAssertEqual(error as? DockerError, .resourceChanged) }
    }

    func testIndividualRemovalNeverForcesOrRemovesVolumes() async throws {
        let stopped = inspectFixture().replacingOccurrences(of: #""Status":"running""#, with: #""Status":"exited""#)
        let original = try DockerParser.containers(Data(stopped.utf8))[0]
        let runner = ScriptedRunner(["local\n", #""unix:///tmp/macstats-test.sock""#, #""daemon-a""#, stopped, containerID, ""])
        let client = DockerClient(runner: runner, environment: [:], executableURL: executable)
        try await client.changeState(container: original, action: .remove, endpoint: endpoint())
        let requests = await runner.requests
        let removal = try XCTUnwrap(requests.first { $0.arguments.contains("rm") })
        XCTAssertEqual(removal.arguments, ["--host", host, "container", "rm", containerID])
    }

    func testChangedDaemonPreventsPrune() async throws {
        let now = Date()
        let plan = try DockerPrune.makePlan(selection: [.danglingImages], endpoint: endpoint(),
                                           storage: .init(endpointIdentity: endpoint().identity, capturedAt: now, rows: []), now: now)
        let runner = ScriptedRunner(["local\n", #""unix:///tmp/macstats-test.sock""#, #""daemon-b""#])
        let report = await DockerClient(runner: runner, environment: [:], executableURL: executable).execute(plan)
        XCTAssertFalse(report.succeeded)
        let requests = await runner.requests
        XCTAssertFalse(requests.contains { $0.arguments.contains("prune") })
    }

    func testRemoteEndpointCannotBypassDiscoveryValidation() async {
        let runner = ScriptedRunner([#""daemon-a""#, ""])
        let client = DockerClient(runner: runner, environment: [:], executableURL: executable)
        let remote = DockerEndpoint(executable: executable, contextName: "remote", host: "ssh://remote", daemonID: "daemon-a")
        do { _ = try await client.snapshot(endpoint: remote); XCTFail("Expected local endpoint validation") }
        catch { XCTAssertEqual(error as? DockerError, .remoteContext) }
        let count = await runner.requests.count
        XCTAssertEqual(count, 0)
    }

    func testPruneReviewExpiringDuringRevalidationCannotMutate() async throws {
        let now = Date()
        let plan = try DockerPrune.makePlan(selection: [.danglingImages], endpoint: endpoint(),
                                           storage: .init(endpointIdentity: endpoint().identity, capturedAt: now, rows: []), now: now)
        let clock = StepClock([now, now.addingTimeInterval(61)])
        let runner = ScriptedRunner(["local\n", #""unix:///tmp/macstats-test.sock""#, #""daemon-a""#, "should not run"])
        let client = DockerClient(runner: runner, environment: [:], executableURL: executable, clock: { clock.now() })
        let report = await client.execute(plan)
        XCTAssertFalse(report.succeeded)
        let requests = await runner.requests
        XCTAssertEqual(requests.count, 3)
        XCTAssertFalse(requests.contains { $0.arguments.contains("prune") })
    }

    func testBuildCachePruneCannotUseAnInheritedBuildxBuilder() async throws {
        let now = Date()
        let plan = try DockerPrune.makePlan(selection: [.buildCache], endpoint: endpoint(),
                                           storage: .init(endpointIdentity: endpoint().identity, capturedAt: now, rows: []), now: now)
        let runner = ScriptedRunner(["local\n", #""unix:///tmp/macstats-test.sock""#, #""daemon-a""#,
                                     "Usage:  docker builder prune\n--keep-storage\n", "Total reclaimed space: 0B\n"])
        let client = DockerClient(runner: runner, environment: ["BUILDX_BUILDER": "unreviewed-remote", "DOCKER_BUILDKIT": "1"],
                                  executableURL: executable)
        let report = await client.execute(plan)
        XCTAssertTrue(report.succeeded)
        let requests = await runner.requests
        let builderRequests = requests.filter { $0.arguments.contains("builder") }
        XCTAssertEqual(builderRequests.count, 2)
        XCTAssertTrue(builderRequests.first?.arguments.contains("--help") == true)
        for request in builderRequests {
            XCTAssertEqual(request.environment["DOCKER_BUILDKIT"], "0")
            XCTAssertEqual(request.arguments.prefix(2), ["--host", host])
        }
    }

    func testBuildCachePruneFailsClosedWhenOnlyBuildxIsAvailable() async throws {
        let now = Date()
        let plan = try DockerPrune.makePlan(selection: [.buildCache], endpoint: endpoint(),
                                           storage: .init(endpointIdentity: endpoint().identity, capturedAt: now, rows: []), now: now)
        let runner = ScriptedRunner(["local\n", #""unix:///tmp/macstats-test.sock""#, #""daemon-a""#,
                                     "Usage:  docker buildx prune\nAliases: docker builder prune\n--keep-storage\n"])
        let report = await DockerClient(runner: runner, environment: [:], executableURL: executable).execute(plan)
        XCTAssertFalse(report.succeeded)
        let requests = await runner.requests
        XCTAssertFalse(requests.contains { $0.arguments.contains("prune") && !$0.arguments.contains("--help") })
    }

    func testOutputLimitDuringPruneIsInconclusiveAndStopsRemainingCategories() async throws {
        let now = Date()
        let plan = try DockerPrune.makePlan(selection: [.danglingImages, .buildCache], endpoint: endpoint(),
                                           storage: .init(endpointIdentity: endpoint().identity, capturedAt: now, rows: []), now: now)
        let runner = ThrowingPruneRunner()
        let report = await DockerClient(runner: runner, environment: [:], executableURL: executable).execute(plan)
        XCTAssertEqual(report.results.count, 2)
        XCTAssertTrue(report.results[0].isInconclusive)
        XCTAssertFalse(report.succeeded)
        let requests = await runner.requests
        XCTAssertEqual(requests.count, 4)
    }

    func inspectFixture() -> String {
        """
        {"Id":"\(containerID)","Name":"/api","Image":"example:latest",
        "State":{"Status":"running","Running":true,"StartedAt":"2026-10-20T08:00:00.000000000Z","FinishedAt":"0001-01-01T00:00:00Z","Health":{"Status":"healthy"}},
        "Labels":{"com.docker.compose.project":"example"},"Mounts":[{"Type":"volume","Name":"data","Destination":"/data"}],
        "Ports":{"80/tcp":[{"HostIp":"127.0.0.1","HostPort":"8080"}]},"Networks":{"example_default":{}}}
        """
    }
}
