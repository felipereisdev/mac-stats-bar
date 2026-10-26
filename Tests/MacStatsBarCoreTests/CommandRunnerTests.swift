import XCTest
@testable import MacStatsBarCore

final class CommandRunnerTests: XCTestCase {
    func testCapturesBothStreamsAndExitStatus() async throws {
        let result = try await CommandRunner().run(CommandRequest(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf hello; printf problem >&2; exit 7"]
        ))
        XCTAssertEqual(result.stdoutText, "hello")
        XCTAssertEqual(result.stderrText, "problem")
        XCTAssertEqual(result.exitCode, 7)
    }

    func testDrainsLargeStdoutAndStderrWithoutDeadlock() async throws {
        let result = try await CommandRunner().run(CommandRequest(
            executable: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: ["-c", "import os; os.write(1, b'a'*300000); os.write(2, b'b'*300000)"],
            timeout: 10
        ))
        XCTAssertEqual(result.stdout.count, 300_000)
        XCTAssertEqual(result.stderr.count, 300_000)
    }

    func testLaunchFailureIsReported() async {
        do {
            _ = try await CommandRunner().run(CommandRequest(executable: URL(fileURLWithPath: "/missing/macstats-command")))
            XCTFail("Expected launch failure")
        } catch {
            guard case CommandFailure.launchFailed = error else { return XCTFail("\(error)") }
        }
    }

    func testTimeoutTerminatesTheProcessPromptly() async {
        let start = Date()
        do {
            _ = try await CommandRunner().run(CommandRequest(
                executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["5"], timeout: 0.05
            ))
            XCTFail("Expected timeout")
        } catch {
            XCTAssertEqual(error as? CommandFailure, .timedOut)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    func testCancellationTerminatesTheProcessPromptly() async {
        let task = Task {
            try await CommandRunner().run(CommandRequest(
                executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["5"]
            ))
        }
        try? await Task.sleep(nanoseconds: 30_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testAlreadyCancelledTaskDoesNotLaunch() async {
        let task = Task {
            try await Task.sleep(nanoseconds: 100_000_000)
            return try await CommandRunner().run(CommandRequest(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["5"]))
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testOutputLimitIsEnforced() async {
        do {
            _ = try await CommandRunner().run(CommandRequest(
                executable: URL(fileURLWithPath: "/usr/bin/python3"),
                arguments: ["-c", "import os; os.write(1, b'a'*300000)"], outputLimit: 1024
            ))
            XCTFail("Expected output limit")
        } catch {
            XCTAssertEqual(error as? CommandFailure, .outputLimitExceeded)
        }
    }
}
