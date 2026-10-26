import Foundation

public struct DockerEndpoint: Sendable, Equatable {
    public let executable: URL
    public let contextName: String
    public let host: String
    public let daemonID: String
    public var identity: String { [executable.path, contextName, host, daemonID].joined(separator: "|") }

    public init(executable: URL, contextName: String, host: String, daemonID: String) {
        self.executable = executable; self.contextName = contextName
        self.host = host; self.daemonID = daemonID
    }
}

public struct ContainerMetrics: Sendable, Equatable {
    public var cpuPercent: Double?
    public var memoryBytes: UInt64?
    public var memoryLimit: UInt64?
    public var networkReceived: UInt64?
    public var networkSent: UInt64?
    public var blockRead: UInt64?
    public var blockWritten: UInt64?

    public init(cpuPercent: Double? = nil, memoryBytes: UInt64? = nil, memoryLimit: UInt64? = nil,
                networkReceived: UInt64? = nil, networkSent: UInt64? = nil,
                blockRead: UInt64? = nil, blockWritten: UInt64? = nil) {
        self.cpuPercent = cpuPercent; self.memoryBytes = memoryBytes; self.memoryLimit = memoryLimit
        self.networkReceived = networkReceived; self.networkSent = networkSent
        self.blockRead = blockRead; self.blockWritten = blockWritten
    }
}

public struct DockerMount: Sendable, Equatable, Decodable {
    public let type: String
    public let name: String?
    public let destination: String
    enum CodingKeys: String, CodingKey { case type = "Type", name = "Name", destination = "Destination" }
}

public struct DockerContainer: Sendable, Identifiable, Equatable {
    public let id: String
    public let name: String
    public let image: String
    public let imageID: String?
    public let state: String
    public let health: String?
    public let startedAtRaw: String
    public let finishedAtRaw: String
    public let labels: [String: String]
    public let mounts: [DockerMount]
    public let ports: String
    public let networks: [String]
    public var metrics: ContainerMetrics
    public var project: String? { labels["com.docker.compose.project"] }
    public var isRunning: Bool { state == "running" }
    public var hasLiveMetrics: Bool { ["running", "paused", "restarting"].contains(state) }
    public var isStopped: Bool { ["exited", "dead", "created"].contains(state) }
    public var hasPersistentMounts: Bool { mounts.contains { ["volume", "bind"].contains($0.type) } }
    public var startedAt: Date? { DockerParser.date(startedAtRaw) }
    public var finishedAt: Date? { DockerParser.date(finishedAtRaw) }
    public var version: String { [id, startedAtRaw, finishedAtRaw, state].joined(separator: "|") }
    public var excludesSuggestions: Bool {
        hasPersistentMounts || labels["macstats.keep"]?.lowercased() == "true"
            || labels.keys.contains { $0.hasPrefix("io.kubernetes.") }
    }

    public init(id: String, name: String, image: String = "", imageID: String? = nil, state: String = "running",
                health: String? = nil, startedAtRaw: String = "", finishedAtRaw: String = "",
                labels: [String: String] = [:], mounts: [DockerMount] = [],
                ports: String = "", networks: [String] = [], metrics: ContainerMetrics = .init()) {
        self.id = id; self.name = name; self.image = image; self.imageID = imageID; self.state = state
        self.health = health; self.startedAtRaw = startedAtRaw; self.finishedAtRaw = finishedAtRaw
        self.labels = labels; self.mounts = mounts; self.ports = ports
        self.networks = networks; self.metrics = metrics
    }
}

public struct DockerSnapshot: Sendable {
    public let endpoint: DockerEndpoint
    public let capturedAt: Date
    public let containers: [DockerContainer]
    public init(endpoint: DockerEndpoint, capturedAt: Date = Date(), containers: [DockerContainer]) {
        self.endpoint = endpoint; self.capturedAt = capturedAt; self.containers = containers
    }
}

public struct DockerStorageRow: Sendable, Identifiable {
    public var id: String { kind }
    public let kind: String
    public let count: Int
    public let active: Int
    public let sizeBytes: UInt64?
    public let reclaimableBytes: UInt64?
}

public struct DockerStorage: Sendable {
    public let endpointIdentity: String
    public let capturedAt: Date
    public let rows: [DockerStorageRow]
    public init(endpointIdentity: String, capturedAt: Date = Date(), rows: [DockerStorageRow]) {
        self.endpointIdentity = endpointIdentity; self.capturedAt = capturedAt; self.rows = rows
    }

    public func needsRefresh(force: Bool = false, now: Date = Date()) -> Bool {
        force || now < capturedAt || now.timeIntervalSince(capturedAt) >= 60
    }
}

public enum DockerAction: Sendable { case start, stop, remove }

public enum DockerError: Error, Equatable, Sendable, LocalizedError {
    case cliMissing, remoteContext, daemonUnavailable, permissionDenied, unsupportedOutput
    case endpointChanged, resourceChanged, stalePlan, emptySelection, actionNotAllowed, busy, cacheCleanupUnsupported
    case commandFailed(String)

    public var errorDescription: String? {
        switch self {
        case .cliMissing: String(localized: "Docker CLI was not found. Choose its path in Settings.")
        case .remoteContext: String(localized: "This Docker context is remote. Choose a local Unix socket context.")
        case .daemonUnavailable: String(localized: "Docker is not responding. Start your container engine and try again.")
        case .permissionDenied: String(localized: "Permission to access the Docker socket was denied.")
        case .unsupportedOutput: String(localized: "This Docker version returned an unsupported data format.")
        case .endpointChanged: String(localized: "The Docker context or engine changed. Refresh and review the action again.")
        case .resourceChanged: String(localized: "This resource changed. Refresh and review it again.")
        case .stalePlan: String(localized: "This cleanup review expired. Refresh storage and review again.")
        case .emptySelection: String(localized: "Choose at least one cleanup category.")
        case .actionNotAllowed: String(localized: "This action is unavailable for the current container state.")
        case .busy: String(localized: "Another Docker action is still running.")
        case .cacheCleanupUnsupported: String(localized: "This Docker CLI cannot safely clean the displayed engine's build cache.")
        case .commandFailed(let detail): detail
        }
    }
}

extension CommandFailure: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .launchFailed: String(localized: "The command could not be started. Check the executable path.")
        case .timedOut: String(localized: "The command timed out. Its action may have completed; refresh before trying again.")
        case .outputLimitExceeded: String(localized: "The command returned too much data. Narrow the selection and try again.")
        }
    }
}
