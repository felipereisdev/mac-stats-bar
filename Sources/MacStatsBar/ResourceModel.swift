import AppKit
import Combine
import MacStatsBarCore

enum ResourceTab: Hashable { case cleanup, suggestions }

struct ContainerRates {
    var received: Double?
    var sent: Double?
    var read: Double?
    var written: Double?
}

@MainActor
final class ResourceModel: ObservableObject {
    @Published var selectedTab: ResourceTab = .cleanup { didSet { restartMonitoring() } }
    @Published private(set) var endpoint: DockerEndpoint?
    @Published private(set) var snapshot: DockerSnapshot?
    @Published private(set) var storage: DockerStorage?
    @Published private(set) var cleanupPreview: DockerCleanupPreview?
    @Published private(set) var recommendations: [ResourceRecommendation] = []
    @Published private(set) var dockerError: String?
    @Published private(set) var feedback: String?
    @Published private(set) var isRefreshing = false
    @Published private(set) var isBusy = false
    @Published private(set) var prunePlan: PrunePlan?
    @Published private(set) var pruneReport: PruneReport?
    @Published private(set) var needsReconciliation = false

    let settings: Settings
    private var client: DockerClient
    private let activitySampler = ActivitySampler()
    private var history = ActivityHistory()
    private var observedApplications: [String: ObservedApplication] = [:]
    private var previousContainers: [String: (container: DockerContainer, time: TimeInterval)] = [:]
    private var pollTask: Task<Void, Never>?
    private var settingsSubscription: AnyCancellable?
    private var observers: [NSObjectProtocol] = []
    private var isVisible = false
    private var isSuspended = false
    private var generation = 0
    private var lastHostSample: TimeInterval = -.infinity
    private var nextDockerAttempt = Date.distantPast
    private var failureCount = 0
    private var previousEnabled: Bool
    private var previousExecutable: String

    var canAct: Bool {
        !isBusy && !isRefreshing && !needsReconciliation && dockerError == nil
            && snapshot.map { Date().timeIntervalSince($0.capturedAt) < 30 } == true
    }

    init(settings: Settings) {
        self.settings = settings
        client = DockerClient(configuredPath: settings.dockerExecutablePath)
        previousEnabled = settings.activitySuggestionsEnabled
        previousExecutable = settings.dockerExecutablePath
        settingsSubscription = settings.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.applySettings() }
        }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.setSuspended(true) }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.setSuspended(false) }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let path = app.bundleURL?.path else { return }
            Task { @MainActor in
                self?.history.reset(resourceID: ResourceID(kind: .application, stableKey: "app:" + path, instanceKey: ""))
                self?.updateRecommendations()
            }
        })
        restartMonitoring()
    }

    func setVisible(_ visible: Bool) { isVisible = visible; restartMonitoring() }

    func shutdown() {
        generation += 1
        pollTask?.cancel(); pollTask = nil
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        observers.removeAll()
        settingsSubscription = nil
    }

    private func setSuspended(_ suspended: Bool) {
        isSuspended = suspended
        resetHistory()
        restartMonitoring()
    }

    private func applySettings() {
        let changed = previousExecutable != settings.dockerExecutablePath || previousEnabled != settings.activitySuggestionsEnabled
        if previousExecutable != settings.dockerExecutablePath {
            client = DockerClient(configuredPath: settings.dockerExecutablePath)
            endpoint = nil; snapshot = nil; storage = nil; cleanupPreview = nil; prunePlan = nil; pruneReport = nil
            dockerError = nil; nextDockerAttempt = .distantPast; failureCount = 0
        }
        previousExecutable = settings.dockerExecutablePath
        previousEnabled = settings.activitySuggestionsEnabled
        if changed { resetHistory(); restartMonitoring() }
        updateRecommendations()
    }

    private func resetHistory() {
        history.resetAll(); observedApplications.removeAll(); previousContainers.removeAll()
        recommendations.removeAll(); lastHostSample = -.infinity
        Task { await activitySampler.reset() }
    }

    private func clearDockerHistory() {
        history.remove(kind: .container); history.remove(kind: .stoppedContainer)
        previousContainers.removeAll()
        updateRecommendations()
    }

    private func restartMonitoring() {
        generation += 1
        pollTask?.cancel()
        guard !isSuspended, !isBusy,
              settings.activitySuggestionsEnabled || (isVisible && selectedTab != .suggestions) else {
            pollTask = nil; return
        }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                do { try await Task.sleep(nanoseconds: self.isVisible ? 5_000_000_000 : 30_000_000_000) }
                catch { return }
            }
        }
    }

    func retry() {
        nextDockerAttempt = .distantPast
        Task { await refresh(force: true) }
    }

    func clearFeedback() { feedback = nil }

    func refresh(force: Bool = false) async {
        guard !isRefreshing, !isBusy, !isSuspended else { return }
        let token = generation
        isRefreshing = true
        defer { isRefreshing = false }
        let uptime = ProcessInfo.processInfo.systemUptime
        if settings.activitySuggestionsEnabled, uptime - lastHostSample >= 25 {
            let apps = ApplicationDescriptors.current()
            let foreground = NSWorkspace.shared.frontmostApplication?.bundleURL?.path
            let values = await activitySampler.sample(applications: apps, foregroundPath: foreground)
            guard !Task.isCancelled, token == generation else { return }
            for old in observedApplications.values where !values.contains(where: { $0.sample.resourceID.stableKey == old.sample.resourceID.stableKey }) {
                history.reset(resourceID: old.sample.resourceID)
            }
            observedApplications = Dictionary(values.map { ($0.sample.resourceID.stableKey, $0) }, uniquingKeysWith: { _, new in new })
            values.forEach { history.record($0.sample) }
            lastHostSample = uptime
            updateRecommendations()
        }
        guard settings.activitySuggestionsEnabled || (isVisible && selectedTab != .suggestions),
              force || Date() >= nextDockerAttempt else { return }
        do {
            let current = try await client.discover()
            // Container metrics are only needed for optional memory suggestions.
            let reading = settings.activitySuggestionsEnabled ? try await client.snapshot(endpoint: current) : nil
            guard !Task.isCancelled, token == generation else { return }
            if endpoint?.identity != current.identity {
                clearDockerHistory(); storage = nil; cleanupPreview = nil; prunePlan = nil; pruneReport = nil
            }
            endpoint = current; snapshot = reading; dockerError = nil
            failureCount = 0; nextDockerAttempt = .distantPast; needsReconciliation = false
            if let reading { observeDocker(reading) }
            if isVisible, selectedTab == .cleanup,
               storage?.needsRefresh(force: force) ?? true {
                let result = try await client.storage(endpoint: current)
                guard !Task.isCancelled, token == generation else { return }
                storage = result
            }
            if isVisible, selectedTab == .cleanup, cleanupPreview?.needsRefresh(force: force) ?? true {
                let preview = try await client.cleanupPreview(endpoint: current)
                guard !Task.isCancelled, token == generation else { return }
                cleanupPreview = preview
            }
        } catch is CancellationError {
            return
        } catch {
            guard token == generation else { return }
            dockerError = error.localizedDescription
            cleanupPreview = nil
            failureCount = min(6, failureCount + 1)
            nextDockerAttempt = Date().addingTimeInterval(min(300, pow(2, Double(failureCount)) * 5))
            clearDockerHistory()
        }
    }

    private func observeDocker(_ reading: DockerSnapshot) {
        let time = ProcessInfo.processInfo.systemUptime
        let oldKeys = Set(previousContainers.keys)
        var next: [String: (container: DockerContainer, time: TimeInterval)] = [:]
        for container in reading.containers where container.isRunning {
            let old = previousContainers[container.id]
            let validOld = old.flatMap { $0.container.version == container.version ? $0 : nil }
            let elapsed = time - (validOld?.time ?? time)
            func rate(_ keyPath: KeyPath<ContainerMetrics, UInt64?>) -> Double? {
                ActivityRate.bytesPerSecond(previous: validOld?.container.metrics[keyPath: keyPath],
                                            current: container.metrics[keyPath: keyPath], elapsed: elapsed)
            }
            let value = ContainerRates(received: rate(\.networkReceived), sent: rate(\.networkSent),
                                       read: rate(\.blockRead), written: rate(\.blockWritten))
            next[container.id] = (container, time)
            if settings.activitySuggestionsEnabled {
                let id = resourceID(container, endpoint: reading.endpoint)
                let network = value.received.flatMap { received in value.sent.map { received + $0 } }
                let block = value.read.flatMap { read in value.written.map { read + $0 } }
                history.record(ResourceActivitySample(
                    resourceID: id, name: container.name, timestamp: time,
                    cpuPercent: container.metrics.cpuPercent, memoryBytes: container.metrics.memoryBytes,
                    networkRate: network, blockRate: block,
                    eligible: !container.excludesSuggestions
                ))
            }
        }
        if settings.activitySuggestionsEnabled {
            for oldID in oldKeys.subtracting(next.keys) {
                if let old = previousContainers[oldID]?.container {
                    history.reset(resourceID: resourceID(old, endpoint: reading.endpoint))
                }
            }
        }
        previousContainers = next
        updateRecommendations()
    }

    private func resourceID(_ container: DockerContainer, endpoint: DockerEndpoint) -> ResourceID {
        ResourceID(kind: .container,
                   stableKey: "docker:" + endpoint.identity + ":" + container.id, instanceKey: container.version)
    }

    private func updateRecommendations() {
        guard settings.activitySuggestionsEnabled else { recommendations = []; return }
        let ignored = settings.suggestionIgnoredUntil.mapValues(Date.init(timeIntervalSince1970:))
        recommendations = RecommendationEngine.suggest(
            history: history,
            policy: RecommendationPolicy(window: Double(settings.activityWindowMinutes * 60),
                                         excludedKeys: Set(settings.suggestionExclusions.keys), ignoredUntil: ignored),
            now: ProcessInfo.processInfo.systemUptime
        )
    }

    func ignore(_ recommendation: ResourceRecommendation, permanently: Bool) {
        if permanently { settings.suggestionExclusions[recommendation.id] = recommendation.name }
        else { settings.suggestionIgnoredUntil[recommendation.id] = Date().addingTimeInterval(86400).timeIntervalSince1970 }
        updateRecommendations()
    }

    private func stop(_ container: DockerContainer) async {
        guard canAct, container.isRunning, let endpoint else { return }
        isBusy = true; pollTask?.cancel()
        defer { isBusy = false; restartMonitoring() }
        guard ResourceActions.confirm(
            title: String(localized: "Stop \(container.name)?"),
            message: String(localized: "The container and its volumes will be kept. Docker may force it to stop after 30 seconds."),
            action: String(localized: "Stop")
        ) else { return }
        needsReconciliation = true; storage = nil; cleanupPreview = nil; prunePlan = nil
        do {
            try await client.changeState(container: container, action: .stop, endpoint: endpoint)
            feedback = String(localized: "The container action completed and its state was verified.")
        } catch { feedback = error.localizedDescription }
    }

    func act(on recommendation: ResourceRecommendation) async {
        guard !isBusy, settings.activitySuggestionsEnabled,
              recommendation.resourceID.kind != .stoppedContainer else { return }
        if recommendation.resourceID.kind != .application {
            guard let endpoint, let container = snapshot?.containers.first(where: {
                resourceID($0, endpoint: endpoint) == recommendation.resourceID
            }) else { feedback = DockerError.resourceChanged.localizedDescription; return }
            await stop(container)
            return
        }
        guard let application = observedApplications[recommendation.id],
              application.sample.resourceID == recommendation.resourceID else {
            feedback = DockerError.resourceChanged.localizedDescription; return
        }
        isBusy = true; pollTask?.cancel()
        defer { isBusy = false; restartMonitoring() }
        guard ResourceActions.confirm(
            title: String(localized: "Quit \(recommendation.name)?"),
            message: String(localized: "The app may have unsaved work. It will be asked to quit normally; memory recovery is not guaranteed."),
            action: String(localized: "Quit")
        ) else { return }
        do {
            let closed = try await ResourceActions.quit(application)
            feedback = closed ? String(localized: "The application closed.")
                : String(localized: "The application is still running. Check for an unsaved-work dialog.")
            history.reset(resourceID: recommendation.resourceID)
            updateRecommendations()
        } catch { feedback = error.localizedDescription }
    }

    func prepareCleanup() async -> Bool {
        guard !isBusy, !isRefreshing else { return false }
        isRefreshing = true
        defer { isRefreshing = false }
        let token = generation
        do {
            let current = try await client.discover()
            let inventory = try await client.storage(endpoint: current)
            let preview = try await client.cleanupPreview(endpoint: current)
            guard !Task.isCancelled, token == generation else { return false }
            if endpoint?.identity != current.identity {
                snapshot = nil; clearDockerHistory(); pruneReport = nil
            }
            endpoint = current; storage = inventory; cleanupPreview = preview; dockerError = nil
            guard !preview.hasNoEstimatedWork else { prunePlan = nil; return false }
            prunePlan = try DockerPrune.makeRecommendedPlan(endpoint: current, storage: inventory)
            return true
        } catch { feedback = error.localizedDescription; prunePlan = nil; return false }
    }

    func executeCleanup() async {
        guard !isBusy, let prunePlan, prunePlan.isRecommended else { return }
        isBusy = true; pollTask?.cancel(); needsReconciliation = true
        cleanupPreview = nil
        defer { self.prunePlan = nil; isBusy = false; restartMonitoring() }
        pruneReport = await client.execute(prunePlan)
        storage = nil
        // Storage presents one compact result, with technical output available on demand.
        feedback = nil
    }
}
