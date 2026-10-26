import XCTest
@testable import MacStatsBarCore

final class PruneResultTests: XCTestCase {
    func result(_ output: String, category: PruneCategory = .danglingImages,
                error: String? = nil, uncertain: Bool = false) -> PruneCategoryResult {
        .init(category: category, output: output, error: error, isInconclusive: uncertain)
    }

    func testZeroBytesIsReportedAsNoSpaceReclaimed() {
        let value = result("Total reclaimed space: 0B\n")
        XCTAssertEqual(value.reclaimedBytes, 0)
        XCTAssertEqual(PruneReport(results: [value]).outcome, .noSpaceReclaimed)
    }

    func testReportedDecimalAndBinarySizesAreParsed() {
        XCTAssertEqual(result("Deleted Images:\ndeleted: sha256:abc\n\nTotal reclaimed space: 1.25GB\n").reclaimedBytes, 1_250_000_000)
        XCTAssertEqual(result("Total reclaimed space: 512KiB\r\n").reclaimedBytes, 524_288)
        XCTAssertEqual(result("Total:\t2MB\n", category: .buildCache).reclaimedBytes, 2_000_000)
    }

    func testUnknownOutputIsNotAssumedToMeanZeroRecovery() {
        let value = result("Deleted Images:\ndeleted: sha256:abc\n")
        XCTAssertNil(value.reclaimedBytes)
        XCTAssertEqual(PruneReport(results: [value]).outcome, .completedWithoutMeasurement)
    }

    func testReportSumsConfirmedCategoryRecoveries() {
        let values = [result("Total reclaimed space: 2MB\n"),
                      result("Total reclaimed space: 3MB\n", category: .stoppedContainers)]
        XCTAssertEqual(PruneReport(results: values).outcome, .reclaimed(5_000_000))
    }

    func testFailedOrUncertainResultCannotClaimRecoveredSpace() {
        for value in [result("Total reclaimed space: 2MB\n", error: "failed"),
                      result("Total reclaimed space: 2MB\n", uncertain: true),
                      result("Total reclaimed space: 0B\n", error: "failed"),
                      result("Total reclaimed space: 0B\n", uncertain: true)] {
            XCTAssertNil(value.reclaimedBytes)
            XCTAssertEqual(PruneReport(results: [value]).outcome, .failed)
        }
    }

    func testMixedUnknownAndMeasuredResultsDoNotInventATotal() {
        let report = PruneReport(results: [result("Total reclaimed space: 2MB\n"),
                                          result("done\n", category: .unusedNetworks)])
        XCTAssertEqual(report.outcome, .completedWithoutMeasurement)
    }

    func testManualRefreshBypassesFreshStorageCache() {
        let now = Date(timeIntervalSince1970: 1000)
        let storage = DockerStorage(endpointIdentity: "local", capturedAt: now, rows: [])
        XCTAssertFalse(storage.needsRefresh(now: now.addingTimeInterval(5)))
        XCTAssertTrue(storage.needsRefresh(force: true, now: now.addingTimeInterval(5)))
        XCTAssertTrue(storage.needsRefresh(now: now.addingTimeInterval(60)))
        XCTAssertTrue(storage.needsRefresh(now: now.addingTimeInterval(-1)))
    }
}
