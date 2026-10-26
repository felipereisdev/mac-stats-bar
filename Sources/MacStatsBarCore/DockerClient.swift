import Foundation

public actor DockerClient {
    private let runner: any CommandRunning
    private let environment: [String: String]
    private let configuredPath: String
    private let executableOverride: URL?
    private let clock: @Sendable () -> Date
    private var mutationInProgress = false

    public init(runner: any CommandRunning = CommandRunner(),
                environment: [String: String] = ProcessInfo.processInfo.environment,
                configuredPath: String = "", executableURL: URL? = nil,
                clock: @escaping @Sendable () -> Date = { Date() }) {
        self.runner = runner; self.environment = environment
        self.configuredPath = configuredPath; self.executableOverride = executableURL
        self.clock = clock
    }

    private var commandEnvironment: [String: String] {
        var clean = environment
        for key in ["DOCKER_HOST", "DOCKER_CONTEXT", "DOCKER_TLS", "DOCKER_TLS_VERIFY", "DOCKER_CERT_PATH"] {
            clean.removeValue(forKey: key)
        }
        clean["LC_ALL"] = "C"
        return clean
    }

    public func discover() async throws -> DockerEndpoint {
        let executable = try locateExecutable()
        let context: String
        let host: String
        if let override = environment["DOCKER_CONTEXT"], !override.isEmpty {
            context = override
            host = try await contextHost(context, executable: executable)
        } else if let override = environment["DOCKER_HOST"], !override.isEmpty {
            context = "DOCKER_HOST"
            host = override
        } else {
            context = try await run(executable: executable, arguments: ["context", "show"]).stdoutText
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !context.isEmpty else { throw DockerError.unsupportedOutput }
            host = try await contextHost(context, executable: executable)
        }
        guard host.hasPrefix("unix:///"), host.count > "unix:///".count,
              !host.contains("\n"), !host.contains("\0") else { throw DockerError.remoteContext }
        let id = try await daemonID(executable: executable, host: host)
        return DockerEndpoint(executable: executable, contextName: context, host: host, daemonID: id)
    }

    private func locateExecutable() throws -> URL {
        if let executableOverride { return executableOverride }
        if !configuredPath.trimmingCharacters(in: .whitespaces).isEmpty {
            let path = (configuredPath as NSString).expandingTildeInPath
            guard path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) else { throw DockerError.cliMissing }
            return URL(fileURLWithPath: path)
        }
        let paths = (environment["PATH"] ?? "").split(separator: ":").filter { $0.hasPrefix("/") }.map { "\($0)/docker" }
            + ["/opt/homebrew/bin/docker", "/usr/local/bin/docker",
               NSHomeDirectory() + "/.docker/bin/docker", "/Applications/Docker.app/Contents/Resources/bin/docker"]
        guard let path = paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { throw DockerError.cliMissing }
        return URL(fileURLWithPath: path)
    }

    private func contextHost(_ name: String, executable: URL) async throws -> String {
        let result = try await run(executable: executable,
                                   arguments: ["context", "inspect", name, "--format", "{{json .Endpoints.docker.Host}}"])
        guard let value = try? JSONDecoder().decode(String.self, from: result.stdout) else { throw DockerError.unsupportedOutput }
        return value
    }

    private func daemonID(executable: URL, host: String) async throws -> String {
        guard host.hasPrefix("unix:///"), host.count > "unix:///".count,
              !host.contains("\n"), !host.contains("\0") else { throw DockerError.remoteContext }
        let result = try await run(executable: executable, arguments: ["--host", host, "info", "--format", "{{json .ID}}"])
        guard let id = try? JSONDecoder().decode(String.self, from: result.stdout), !id.isEmpty else {
            throw DockerError.unsupportedOutput
        }
        return id
    }

    private func validateDaemon(_ endpoint: DockerEndpoint) async throws {
        guard try await daemonID(executable: endpoint.executable, host: endpoint.host) == endpoint.daemonID else {
            throw DockerError.endpointChanged
        }
    }

    private func validateCurrentEndpoint(_ endpoint: DockerEndpoint) async throws {
        guard try await discover().identity == endpoint.identity else { throw DockerError.endpointChanged }
    }

    private func run(executable: URL, arguments: [String], timeout: TimeInterval = 15,
                     environmentOverrides: [String: String] = [:]) async throws -> CommandResult {
        try Task.checkCancellation()
        let result = try await runner.run(CommandRequest(executable: executable, arguments: arguments,
                                                         environment: commandEnvironment.merging(environmentOverrides) { _, override in override },
                                                         timeout: timeout))
        guard result.exitCode == 0 else {
            let detail = result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = detail.lowercased()
            if lower.contains("permission denied") { throw DockerError.permissionDenied }
            if lower.contains("cannot connect") || lower.contains("is the docker daemon running")
                || lower.contains("connection refused") || lower.contains("no such file or directory") {
                throw DockerError.daemonUnavailable
            }
            throw DockerError.commandFailed(detail.isEmpty ? String(localized: "The Docker command failed.") : String(detail.prefix(600)))
        }
        return result
    }

    private func run(_ endpoint: DockerEndpoint, _ arguments: [String], timeout: TimeInterval = 15,
                     environmentOverrides: [String: String] = [:]) async throws -> CommandResult {
        guard endpoint.host.hasPrefix("unix:///"), !endpoint.host.contains("\n"), !endpoint.host.contains("\0") else {
            throw DockerError.remoteContext
        }
        return try await run(executable: endpoint.executable, arguments: ["--host", endpoint.host] + arguments,
                             timeout: timeout, environmentOverrides: environmentOverrides)
    }

    public func snapshot(endpoint: DockerEndpoint) async throws -> DockerSnapshot {
        guard !mutationInProgress else { throw DockerError.busy }
        try await validateDaemon(endpoint)
        var containers = try await readContainers(endpoint: endpoint)
        let running = containers.filter(\.hasLiveMetrics).map(\.id)
        var metrics: [String: ContainerMetrics] = [:]
        if !running.isEmpty {
            for start in stride(from: 0, to: running.count, by: 50) {
                let sample = try await run(endpoint, ["container", "stats", "--no-stream", "--no-trunc", "--format", "{{json .}}"]
                                          + Array(running[start..<min(start + 50, running.count)]), timeout: 20)
                metrics.merge(try DockerParser.stats(sample.stdout)) { _, new in new }
            }
        }
        for index in containers.indices { containers[index].metrics = metrics[containers[index].id] ?? .init() }
        return DockerSnapshot(endpoint: endpoint, containers: containers)
    }

    private static let inspectFormat = #"{"Id":{{json .Id}},"Name":{{json .Name}},"Image":{{json .Config.Image}},"ImageID":{{json .Image}},"State":{"Status":{{json .State.Status}},"StartedAt":{{json .State.StartedAt}},"FinishedAt":{{json .State.FinishedAt}},"Health":{{with index .State "Health"}}{"Status":{{json .Status}}}{{else}}null{{end}}},"Labels":{{json (index .Config "Labels")}},"Mounts":{{json (index . "Mounts")}},"Ports":{{json (index .NetworkSettings "Ports")}},"Networks":{{json (index .NetworkSettings "Networks")}}}"#

    private func readContainers(endpoint: DockerEndpoint) async throws -> [DockerContainer] {
        let result = try await run(endpoint, ["container", "ls", "--all", "--no-trunc", "--format", "{{json .ID}}"])
        let ids = try DockerParser.rows(result.stdout, as: String.self)
        guard ids.allSatisfy(Self.isContainerID) else { throw DockerError.unsupportedOutput }
        var containers: [DockerContainer] = []
        // Bound argument sizes and avoid collecting Config.Env in inspect output.
        for start in stride(from: 0, to: ids.count, by: 50) {
            containers += try await inspect(Array(ids[start..<min(start + 50, ids.count)]), endpoint: endpoint)
        }
        return containers
    }

    private static func isContainerID(_ id: String) -> Bool {
        id.count == 64 && id.allSatisfy { $0.isASCII && ($0.isNumber || ("a"..."f").contains(String($0))) }
    }

    private func inspect(_ ids: [String], endpoint: DockerEndpoint) async throws -> [DockerContainer] {
        guard !ids.isEmpty, ids.allSatisfy(Self.isContainerID) else { throw DockerError.actionNotAllowed }
        let result = try await run(endpoint, ["container", "inspect", "--format", Self.inspectFormat] + ids)
        let containers = try DockerParser.containers(result.stdout)
        guard Set(containers.map(\.id)) == Set(ids), containers.count == ids.count else { throw DockerError.resourceChanged }
        return containers
    }

    public func storage(endpoint: DockerEndpoint) async throws -> DockerStorage {
        guard !mutationInProgress else { throw DockerError.busy }
        try await validateDaemon(endpoint)
        let result = try await run(endpoint, ["system", "df", "--format", "{{json .}}"], timeout: 45)
        return DockerStorage(endpointIdentity: endpoint.identity, rows: try DockerParser.storageRows(result.stdout))
    }

    public func cleanupPreview(endpoint: DockerEndpoint) async throws -> DockerCleanupPreview {
        guard !mutationInProgress else { throw DockerError.busy }
        try await validateDaemon(endpoint)
        let timeResult = try await run(endpoint, ["info", "--format", "{{json .SystemTime}}"])
        let daemonTime = (try? JSONDecoder().decode(String.self, from: timeResult.stdout)).flatMap(DockerParser.date)
        let images: [DockerCleanupImage]?
        do {
            let result = try await readEngineJSON("/images/json?all=1&shared-size=1&container-count=1", endpoint: endpoint)
            images = try JSONDecoder().decode([DockerCleanupImage].self, from: result)
        } catch is CancellationError { throw CancellationError() }
        catch { images = nil }
        let cache: [DockerCleanupCache]?
        do {
            let result = try await readEngineJSON("/system/df?type=build-cache", endpoint: endpoint)
            cache = try JSONDecoder().decode(CachePreviewResponse.self, from: result).records
        } catch is CancellationError { throw CancellationError() }
        catch { cache = nil }
        let agedImageIDs: Set<String>?
        do {
            let result = try await run(endpoint, ["image", "ls", "--all", "--no-trunc",
                                                 "--filter", DockerCleanupPolicy.imageAgeFilter,
                                                 "--format", "{{json .ID}}"])
            agedImageIDs = Set(try DockerParser.rows(result.stdout, as: String.self).map(DockerImage.canonicalID))
        } catch is CancellationError { throw CancellationError() }
        catch { agedImageIDs = nil }
        let cacheSupported: Bool
        do { try await validateBuildCacheCleanup(endpoint); cacheSupported = true }
        catch is CancellationError { throw CancellationError() }
        catch { cacheSupported = false }
        try await validateDaemon(endpoint)
        return DockerCleanupEstimator.estimate(endpointIdentity: endpoint.identity, images: images, cache: cache,
                                               ageEligibleImageIDs: agedImageIDs, daemonTime: daemonTime,
                                               capturedAt: clock(), cacheCleanupSupported: cacheSupported)
    }

    private struct CachePreviewResponse: Decodable {
        let records: [DockerCleanupCache]?
        enum CodingKeys: String, CodingKey { case records = "BuildCache" }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            records = values.contains(.records) ? try values.decodeIfPresent([DockerCleanupCache].self, forKey: .records) ?? [] : nil
        }
    }

    private func readEngineJSON(_ path: String, endpoint: DockerEndpoint) async throws -> Data {
        guard endpoint.host.hasPrefix("unix:///"),
              let socket = URLComponents(string: endpoint.host)?.path, socket.hasPrefix("/"),
              !socket.contains("\0"), !socket.contains("\n") else { throw DockerError.remoteContext }
        // curl is only a bounded GET transport for this already-validated local socket.
        // Typed endpoints avoid collecting container command lines; no response body is logged.
        let result = try await run(executable: URL(fileURLWithPath: "/usr/bin/curl"),
                                   arguments: ["--disable", "--silent", "--show-error", "--fail", "--noproxy", "*",
                                               "--proto", "=http", "--max-time", "25", "--request", "GET",
                                               "--unix-socket", socket, "http://localhost" + path], timeout: 30)
        return result.stdout
    }

    private func validateBuildCacheCleanup(_ endpoint: DockerEndpoint) async throws {
        let help = try await run(endpoint, ["builder", "prune", "--help"], environmentOverrides: ["DOCKER_BUILDKIT": "0"])
        guard help.stdoutText.range(of: #"(?m)^Usage:\s+docker builder prune(?:\s|$)"#,
                                    options: .regularExpression) != nil,
              help.stdoutText.contains("--keep-storage") else { throw DockerError.cacheCleanupUnsupported }
    }

    public func images(endpoint: DockerEndpoint) async throws -> DockerImageInventory {
        guard !mutationInProgress else { throw DockerError.busy }
        try await validateDaemon(endpoint)
        let result = try await run(endpoint, ["image", "ls", "--all", "--no-trunc", "--format", "{{json .ID}}"])
        let ids = Array(Set(try DockerParser.rows(result.stdout, as: String.self).map(DockerImage.canonicalID))).sorted()
        var images: [DockerImage] = []
        let format = #"{"Id":{{json .Id}},"RepoTags":{{json (index . "RepoTags")}},"Size":{{json .Size}},"Created":{{json .Created}}}"#
        for start in stride(from: 0, to: ids.count, by: 50) {
            let batch = Array(ids[start..<min(start + 50, ids.count)])
            let result = try await run(endpoint, ["image", "inspect", "--format", format] + batch)
            let inspected = try DockerParser.images(result.stdout)
            guard inspected.count == batch.count, Set(inspected.map(\.id)) == Set(batch) else {
                throw DockerError.resourceChanged
            }
            images += inspected
        }
        let containers = images.isEmpty ? [] : try await readContainers(endpoint: endpoint)
        let linked = try DockerImageInventory.link(images: images, containers: containers)
        try await validateDaemon(endpoint)
        return DockerImageInventory(endpointIdentity: endpoint.identity, capturedAt: clock(), images: linked)
    }

    public func changeState(container: DockerContainer, action: DockerAction, endpoint: DockerEndpoint) async throws {
        guard !mutationInProgress else { throw DockerError.busy }
        mutationInProgress = true
        defer { mutationInProgress = false }
        try await validateCurrentEndpoint(endpoint)
        let current = try await inspect([container.id], endpoint: endpoint)
        guard let current = current.first, current.version == container.version else { throw DockerError.resourceChanged }
        let arguments: [String]
        switch action {
        case .stop:
            guard current.isRunning else { throw DockerError.actionNotAllowed }
            arguments = ["container", "stop", "--time", "30", container.id]
        case .start:
            guard current.isStopped else { throw DockerError.actionNotAllowed }
            arguments = ["container", "start", container.id]
        case .remove:
            guard current.isStopped else { throw DockerError.actionNotAllowed }
            arguments = ["container", "rm", container.id]
        }
        _ = try await run(endpoint, arguments, timeout: 45)
        if action == .remove {
            let remaining = try await run(endpoint, ["container", "ls", "--all", "--no-trunc", "--filter", "id=\(container.id)", "--format", "{{json .ID}}"])
            guard try DockerParser.rows(remaining.stdout, as: String.self).isEmpty else { throw DockerError.resourceChanged }
        } else {
            let updated = try await inspect([container.id], endpoint: endpoint).first
            guard let updated, action == .start ? updated.isRunning : updated.isStopped else { throw DockerError.resourceChanged }
        }
    }

    public func execute(_ plan: PrunePlan) async -> PruneReport {
        guard !mutationInProgress else { return failedReport(plan, error: DockerError.busy) }
        guard clock() < plan.expiresAt else { return failedReport(plan, error: DockerError.stalePlan) }
        mutationInProgress = true
        defer { mutationInProgress = false }
        var results: [PruneCategoryResult] = []
        var stopError: Error?
        for category in plan.categories {
            if let stopError {
                results.append(.init(category: category, output: "", error: stopError.localizedDescription, isInconclusive: false))
                continue
            }
            do {
                try Task.checkCancellation()
                try await validateCurrentEndpoint(plan.endpoint)
                var overrides: [String: String] = [:]
                if category == .buildCache {
                    // Modern CLIs may forward "builder prune" to an independently selected
                    // Buildx node. Require the built-in handler bound to this Docker client.
                    overrides["DOCKER_BUILDKIT"] = "0"
                    try await validateBuildCacheCleanup(plan.endpoint)
                }
                guard clock() < plan.expiresAt else { throw DockerError.stalePlan }
                let output = try await run(plan.endpoint, category.arguments, timeout: 120, environmentOverrides: overrides)
                results.append(.init(category: category, output: output.stdoutText, error: nil, isInconclusive: false))
            } catch {
                let uncertain = error is CancellationError || (error as? CommandFailure) == .timedOut
                    || (error as? CommandFailure) == .outputLimitExceeded
                results.append(.init(category: category, output: "", error: error.localizedDescription, isInconclusive: uncertain))
                // Revalidate on the next explicit attempt; never retry a timed-out mutation.
                if uncertain || (error as? DockerError) == .endpointChanged || (error as? DockerError) == .stalePlan { stopError = error }
            }
        }
        return PruneReport(results: results)
    }

    private func failedReport(_ plan: PrunePlan, error: Error) -> PruneReport {
        PruneReport(results: plan.categories.map {
            .init(category: $0, output: "", error: error.localizedDescription, isInconclusive: false)
        })
    }
}
