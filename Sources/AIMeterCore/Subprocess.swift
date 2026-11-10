import Foundation
import os

enum Subprocess {
    struct Failure: Error {}

    /// What happens to a process that outlives the caller's timeout.
    enum OnTimeout {
        /// Terminate the process. Right for read-only tools.
        case terminate
        /// Stop waiting but let the process finish. Right for a process that may be
        /// writing state, such as a CLI that saves a refreshed login.
        case detach
    }

    /// Runs `executable` and returns its standard output. Throws on a nonzero exit
    /// and when the process outlives `timeout`.
    static func run(
        _ executable: String,
        _ arguments: [String],
        environment: [String: String]? = nil,
        timeout: TimeInterval = 20,
        onTimeout: OnTimeout = .terminate
    ) async throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()

        // Whichever finishes first, the process or the timer, resumes the caller. After a
        // `.detach` timeout the reader keeps going until the process closes its output.
        return try await withCheckedThrowingContinuation { continuation in
            let pending = OSAllocatedUnfairLock<CheckedContinuation<Data, any Error>?>(initialState: continuation)
            let finish: @Sendable (Result<Data, any Error>) -> Void = { result in
                pending.withLock { pending in
                    defer { pending = nil }
                    return pending
                }?.resume(with: result)
            }
            DispatchQueue.global().async {
                // Drain before waiting so a large payload can't fill the pipe and deadlock.
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let succeeded = process.terminationReason == .exit && process.terminationStatus == 0
                finish(succeeded ? .success(data) : .failure(Failure()))
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if onTimeout == .terminate, process.isRunning { process.terminate() }
                finish(.failure(Failure()))
            }
        }
    }
}
