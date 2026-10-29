import Foundation

struct ProcessResult: Sendable {
    var exitCode: Int32
    var stdout: Data
    var stderr: Data

    var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
    var stderrString: String { String(decoding: stderr, as: UTF8.self) }
}

enum ProcessRunnerError: Error, CustomStringConvertible {
    case timedOut(String, Duration)

    var description: String {
        switch self {
        case let .timedOut(executable, timeout): "\(executable) timed out after \(timeout)"
        }
    }
}

/// Runs an executable found on `PATH` and captures its output.
enum ProcessRunner {
    static func run(_ executable: String, _ arguments: [String], timeout: Duration? = nil) async throws -> ProcessResult {
        let box = ProcessBox()
        let process = box.process
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [executable] + arguments
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice
        // Registered before launch, so an instantly exiting process can't be missed.
        // (`waitUntilExit()` can hang forever when called from a background thread.)
        let exit = ExitWaiter()
        process.terminationHandler = { exit.finish($0.terminationStatus) }

        try process.run()

        let timeoutTask = timeout.map { timeout in
            Task {
                try await Task.sleep(for: timeout)
                box.timedOut = true
                box.process.terminate()
            }
        }

        // Drain both pipes concurrently so a chatty process can't block on a full pipe buffer.
        async let out = readToEnd(outPipe.fileHandleForReading)
        async let err = readToEnd(errPipe.fileHandleForReading)
        let (stdout, stderr) = await (out, err)
        let status = await exit.wait()
        timeoutTask?.cancel()

        if box.timedOut, let timeout {
            throw ProcessRunnerError.timedOut(executable, timeout)
        }
        return ProcessResult(exitCode: status, stdout: stdout, stderr: stderr)
    }

    private static func readToEnd(_ handle: FileHandle) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: handle.readDataToEndOfFile())
            }
        }
    }

}

/// Bridges `terminationHandler` to async/await, whether the process exits before or after `wait()`.
private final class ExitWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var status: Int32?
    private var continuation: CheckedContinuation<Int32, Never>?

    func finish(_ status: Int32) {
        lock.lock()
        if let continuation {
            self.continuation = nil
            lock.unlock()
            continuation.resume(returning: status)
        } else {
            self.status = status
            lock.unlock()
        }
    }

    func wait() async -> Int32 {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let status {
                lock.unlock()
                continuation.resume(returning: status)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }
}

/// `Process` is not `Sendable`; access is confined to the runner above.
private final class ProcessBox: @unchecked Sendable {
    let process = Process()
    var timedOut = false
}
