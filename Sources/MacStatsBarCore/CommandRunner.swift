import Foundation
import Darwin

public struct CommandRequest: Sendable {
    public let executable: URL
    public let arguments: [String]
    public let environment: [String: String]
    public let timeout: TimeInterval
    public let outputLimit: Int

    public init(executable: URL, arguments: [String] = [],
                environment: [String: String] = ProcessInfo.processInfo.environment,
                timeout: TimeInterval = 15, outputLimit: Int = 4 * 1024 * 1024) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.timeout = timeout
        self.outputLimit = max(1, outputLimit)
    }
}

public struct CommandResult: Sendable, Equatable {
    public let stdout: Data
    public let stderr: Data
    public let exitCode: Int32
    public var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrText: String { String(decoding: stderr, as: UTF8.self) }

    public init(stdout: Data = Data(), stderr: Data = Data(), exitCode: Int32 = 0) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }
}

public enum CommandFailure: Error, Equatable, Sendable {
    case launchFailed(String)
    case timedOut
    case outputLimitExceeded
}

public protocol CommandRunning: Sendable {
    func run(_ request: CommandRequest) async throws -> CommandResult
}

public struct CommandRunner: CommandRunning {
    public init() {}

    public func run(_ request: CommandRequest) async throws -> CommandResult {
        try Task.checkCancellation()
        let execution = ProcessExecution()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(with: Result { try execution.execute(request) })
                }
            }
        } onCancel: {
            execution.stop(CancellationError())
        }
    }
}

private final class ProcessExecution: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var failure: Error?
    private var finished = false

    func stop(_ error: Error) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        if failure == nil { failure = error }
        if let process, process.isRunning { process.terminate() }
        lock.unlock()
        // Some tools ignore SIGTERM. Only signal this still-running Process object.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.25) { [self] in
            lock.lock()
            defer { lock.unlock() }
            if !finished, let process, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
    }

    func execute(_ request: CommandRequest) throws -> CommandResult {
        let child = Process()
        let output = Pipe(), errors = Pipe()
        child.executableURL = request.executable
        child.arguments = request.arguments
        child.environment = request.environment
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = output
        child.standardError = errors
        let stdout = StreamCapture(handle: output.fileHandleForReading, limit: request.outputLimit) { [weak self] in
            self?.stop(CommandFailure.outputLimitExceeded)
        }
        let stderr = StreamCapture(handle: errors.fileHandleForReading, limit: request.outputLimit) { [weak self] in
            self?.stop(CommandFailure.outputLimitExceeded)
        }
        lock.lock()
        if let failure {
            finished = true
            lock.unlock()
            _ = stdout.finish(); _ = stderr.finish()
            throw failure
        }
        process = child
        do {
            try child.run()
        } catch {
            finished = true
            lock.unlock()
            _ = stdout.finish(); _ = stderr.finish()
            throw CommandFailure.launchFailed(error.localizedDescription)
        }
        lock.unlock()

        let timeout = DispatchWorkItem { [weak self] in self?.stop(CommandFailure.timedOut) }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + max(0, request.timeout), execute: timeout)
        child.waitUntilExit()
        timeout.cancel()
        let capturedOutput = stdout.finish(), capturedErrors = stderr.finish()
        lock.lock()
        finished = true
        let error = failure
        process = nil
        lock.unlock()
        if let error { throw error }
        return CommandResult(stdout: capturedOutput, stderr: capturedErrors, exitCode: child.terminationStatus)
    }
}

/// Nonblocking reads avoid both full-pipe deadlocks and inherited-pipe hangs.
private final class StreamCapture: @unchecked Sendable {
    private let queue = DispatchQueue(label: "MacStatsBar.command.capture")
    private let handle: FileHandle
    private let source: DispatchSourceRead
    private let limit: Int
    private let exceeded: @Sendable () -> Void
    private var data = Data()
    private var closed = false
    private var didExceed = false

    init(handle: FileHandle, limit: Int, exceeded: @escaping @Sendable () -> Void) {
        self.handle = handle
        self.limit = limit
        self.exceeded = exceeded
        let descriptor = handle.fileDescriptor
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in self?.readAvailable() }
        source.resume()
    }

    private func readAvailable() {
        guard !closed else { return }
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = Darwin.read(handle.fileDescriptor, &buffer, buffer.count)
            if count > 0 {
                let remaining = max(0, limit - data.count)
                data.append(contentsOf: buffer.prefix(min(count, remaining)))
                if count > remaining, !didExceed {
                    didExceed = true
                    exceeded()
                }
            } else if count < 0, errno == EINTR {
                continue
            } else {
                if count == 0 { source.cancel() }
                return
            }
        }
    }

    func finish() -> Data {
        queue.sync {
            readAvailable()
            closed = true
            source.cancel()
            try? handle.close()
            return data
        }
    }
}
