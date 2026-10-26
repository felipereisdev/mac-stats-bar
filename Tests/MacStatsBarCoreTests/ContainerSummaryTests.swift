import XCTest
@testable import MacStatsBarCore

final class ContainerSummaryTests: XCTestCase {
    func testTotalsSumLiveContainersWithoutCountingStoppedMissingMetricsAsUnknown() {
        let values = [
            DockerContainer(id: "a", name: "A", metrics: .init(cpuPercent: 120, memoryBytes: 1024)),
            DockerContainer(id: "b", name: "B", metrics: .init(cpuPercent: 0.5, memoryBytes: 2048)),
            DockerContainer(id: "c", name: "Stopped", state: "exited")
        ]
        let totals = ContainerSummary(containers: values)
        XCTAssertEqual(totals.totalCount, 3)
        XCTAssertEqual(totals.runningCount, 2)
        XCTAssertEqual(totals.cpuPercent, 120.5)
        XCTAssertEqual(totals.memoryBytes, 3072)
    }

    func testMissingLiveMeasurementsAreNotSummedAsZero() {
        let values = [
            DockerContainer(id: "a", name: "A", metrics: .init(cpuPercent: 1, memoryBytes: 1024)),
            DockerContainer(id: "b", name: "B")
        ]
        let totals = ContainerSummary(containers: values)
        XCTAssertNil(totals.cpuPercent)
        XCTAssertNil(totals.memoryBytes)
    }

    func testPausedContainerMemoryIsIncludedAndMissingPausedDataIsUnknown() {
        let paused = DockerContainer(id: "a", name: "A", state: "paused", metrics: .init(cpuPercent: 0, memoryBytes: 2048))
        XCTAssertEqual(ContainerSummary(containers: [paused]).memoryBytes, 2048)
        XCTAssertNil(ContainerSummary(containers: [.init(id: "b", name: "B", state: "paused")]).memoryBytes)
    }

    func testEmptySelectionHasZeroKnownConsumptionAndOverflowIsUnknown() {
        let empty = ContainerSummary(containers: [])
        XCTAssertEqual(empty.cpuPercent, 0)
        XCTAssertEqual(empty.memoryBytes, 0)
        let values = [
            DockerContainer(id: "a", name: "A", metrics: .init(cpuPercent: 0, memoryBytes: UInt64.max)),
            DockerContainer(id: "b", name: "B", metrics: .init(cpuPercent: 0, memoryBytes: 1))
        ]
        XCTAssertNil(ContainerSummary(containers: values).memoryBytes)
    }
}
