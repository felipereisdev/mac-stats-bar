import XCTest
@testable import MacStatsBarCore

final class ActivityHistoryTests: XCTestCase {
    let app = ResourceID(kind: .application, stableKey: "app:example", instanceKey: "pid100:start1")
    let container = ResourceID(kind: .container, stableKey: "docker:daemon:id", instanceKey: "started1")

    func sample(_ time: Double, id: ResourceID? = nil, cpu: Double? = 0.1,
                memory: UInt64? = 300 * 1_048_576, network: Double? = 0,
                block: Double? = 0, foreground: Bool = false, eligible: Bool = true) -> ResourceActivitySample {
        ResourceActivitySample(resourceID: id ?? app, name: "Example", timestamp: time,
                               cpuPercent: cpu, memoryBytes: memory, networkRate: network,
                               blockRate: block, isForeground: foreground, eligible: eligible)
    }

    func quietHistory(id: ResourceID? = nil) -> ActivityHistory {
        var history = ActivityHistory()
        for time in stride(from: 0.0, through: 900, by: 30) { history.record(sample(time, id: id)) }
        return history
    }

    func suggestions(_ history: ActivityHistory, now: Double = 900, policy: RecommendationPolicy = .init()) -> [ResourceRecommendation] {
        RecommendationEngine.suggest(history: history, policy: policy, now: now)
    }

    func testFullQuietWindowSuggestsAppWithObservedDuration() {
        let values = suggestions(quietHistory())
        XCTAssertEqual(values.count, 1)
        XCTAssertEqual(values.first?.resourceID, app)
        XCTAssertEqual(values.first?.observedDuration, 900)
    }

    func testNoRecommendationBeforeWholeWindow() {
        XCTAssertTrue(suggestions(quietHistory(), now: 899).isEmpty)
    }

    func testCPUAtThresholdIsActivityNotIdle() {
        var history = quietHistory()
        history.record(sample(930, cpu: 1))
        XCTAssertTrue(suggestions(history, now: 930).isEmpty)
    }

    func testMissingCPUIsNotZero() {
        var history = quietHistory()
        history.record(sample(930, cpu: nil))
        XCTAssertTrue(suggestions(history, now: 930).isEmpty)
    }

    func testLowMemoryAppIsNotRecommended() {
        var history = quietHistory()
        history.record(sample(930, memory: 255 * 1_048_576))
        XCTAssertTrue(suggestions(history, now: 930).isEmpty)
    }

    func testForegroundAndIneligibleAppsAreExcluded() {
        var history = quietHistory()
        history.record(sample(930, foreground: true))
        XCTAssertTrue(suggestions(history, now: 930).isEmpty)
        history.record(sample(960, eligible: false))
        XCTAssertTrue(suggestions(history, now: 960).isEmpty)
    }

    func testPIDReuseAndContainerRestartResetHistory() {
        for id in [app, container] {
            var history = quietHistory(id: id)
            let replacement = ResourceID(kind: id.kind, stableKey: id.stableKey, instanceKey: "replacement")
            history.record(sample(930, id: replacement))
            XCTAssertTrue(suggestions(history, now: 930).isEmpty)
        }
    }

    func testNinetySecondGapIsAllowedButLargerGapResetsWindow() {
        var history = quietHistory()
        history.record(sample(990))
        XCTAssertEqual(suggestions(history, now: 990).count, 1)
        history.record(sample(1081))
        XCTAssertTrue(suggestions(history, now: 1081).isEmpty)
    }

    func testInsufficientCoverageDoesNotCountAsIdle() {
        var history = ActivityHistory()
        for time in stride(from: 0.0, through: 900, by: 60) { history.record(sample(time)) }
        XCTAssertTrue(suggestions(history).isEmpty)
    }

    func testDenseBurstsDoNotFillMissingObservationIntervals() {
        var history = ActivityHistory()
        for time in stride(from: 0.0, through: 900, by: 90) {
            for offset in [0.0, 1, 2] where time + offset <= 900 { history.record(sample(time + offset)) }
        }
        XCTAssertTrue(suggestions(history).isEmpty)
    }

    func testStaleSamplesAreNotSuggested() {
        XCTAssertTrue(suggestions(quietHistory(), now: 991).isEmpty)
    }

    func testContainerRequiresNetworkAndDiskSignalsBelowThreshold() {
        XCTAssertEqual(suggestions(quietHistory(id: container)).count, 1)
        var history = quietHistory(id: container)
        history.record(sample(930, id: container, network: 1024))
        XCTAssertTrue(suggestions(history, now: 930).isEmpty)
        history = quietHistory(id: container)
        history.record(sample(930, id: container, block: 4096))
        XCTAssertTrue(suggestions(history, now: 930).isEmpty)
        history = quietHistory(id: container)
        history.record(sample(930, id: container, network: nil))
        XCTAssertTrue(suggestions(history, now: 930).isEmpty)
    }

    func testIgnoredAndExcludedResourcesAreNotSuggested() {
        let history = quietHistory()
        XCTAssertTrue(suggestions(history, policy: .init(excludedKeys: [app.stableKey])).isEmpty)
        XCTAssertTrue(suggestions(history, policy: .init(ignoredUntil: [app.stableKey: Date().addingTimeInterval(60)])).isEmpty)
        XCTAssertEqual(suggestions(history, policy: .init(ignoredUntil: [app.stableKey: .distantPast])).count, 1)
    }

    func testResetAndRetainRemoveStaleResourceHistory() {
        var history = quietHistory()
        history.reset(resourceID: app)
        XCTAssertTrue(suggestions(history).isEmpty)
        history = quietHistory()
        history.retain(stableKeys: [])
        XCTAssertTrue(suggestions(history).isEmpty)
    }

    func testCounterResetAndMissingSamplesHaveNoRate() {
        XCTAssertEqual(ActivityRate.bytesPerSecond(previous: 10, current: 40, elapsed: 30), 1)
        XCTAssertNil(ActivityRate.bytesPerSecond(previous: 40, current: 10, elapsed: 30))
        XCTAssertNil(ActivityRate.bytesPerSecond(previous: nil, current: 0, elapsed: 30))
        XCTAssertNil(ActivityRate.bytesPerSecond(previous: 0, current: 0, elapsed: 0))
    }

    func testOutOfOrderSampleCannotExtendAnIdleWindow() {
        var history = quietHistory()
        history.record(sample(500))
        XCTAssertTrue(suggestions(history).isEmpty)
    }

    func testProcessIdentityIncludesStartTimeOwnerAndExecutable() {
        let original = ProcessIdentity(pid: 100, ownerUID: 501, executable: "/Applications/A.app/Contents/MacOS/A", startTime: 1)
        XCTAssertNotEqual(original, ProcessIdentity(pid: 100, ownerUID: 501, executable: original.executable, startTime: 2))
        XCTAssertNotEqual(original, ProcessIdentity(pid: 100, ownerUID: 0, executable: original.executable, startTime: 1))
        XCTAssertNotEqual(original, ProcessIdentity(pid: 100, ownerUID: 501, executable: "/usr/bin/other", startTime: 1))
    }

    func testOldStoppedContainerIsNotAMemoryReleaseSuggestion() {
        let now = Date()
        var history = ActivityHistory()
        let stopped = ResourceID(kind: .stoppedContainer, stableKey: "stopped", instanceKey: "finished1")
        history.record(ResourceActivitySample(resourceID: stopped, name: "Old", timestamp: 900,
                                              stoppedAt: now.addingTimeInterval(-7 * 86400)))
        let values = RecommendationEngine.suggest(history: history, policy: .init(), now: 900, wallTime: now)
        XCTAssertTrue(values.isEmpty, "Removing a stopped container does not release running memory.")
        history.reset(resourceID: stopped)
        history.record(ResourceActivitySample(resourceID: stopped, name: "Recent", timestamp: 900,
                                              stoppedAt: now.addingTimeInterval(-3600)))
        XCTAssertTrue(RecommendationEngine.suggest(history: history, policy: .init(), now: 900, wallTime: now).isEmpty)
    }

    func testStoppedContainerCannotFallThroughToIdleRunningRules() {
        let stopped = ResourceID(kind: .stoppedContainer, stableKey: "stopped", instanceKey: "finished1")
        XCTAssertTrue(suggestions(quietHistory(id: stopped)).isEmpty)
    }

    func testContainersWithoutObservedMemoryAreNotSuggestedForMemoryRelease() {
        for memory: UInt64? in [nil, 0] {
            var history = quietHistory(id: container)
            history.record(sample(930, id: container, memory: memory))
            XCTAssertTrue(suggestions(history, now: 930).isEmpty)
        }
    }
}
