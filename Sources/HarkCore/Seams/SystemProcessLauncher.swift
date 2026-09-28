import Foundation
import os

/// `ProcessLaunching` on Foundation's `Process`.
///
/// Launching, draining the pipes and reaping the child all block, so the whole sequence runs on `queue` rather
/// than on a cooperative thread. The queue is concurrent because one `run` occupies three slots on it: the wait
/// and one reader per pipe. Both pipes are drained in parallel for the usual reason — a child that fills the
/// 64 KiB stderr buffer while we are blocked reading stdout never exits.
public struct SystemProcessLauncher: ProcessLaunching {
    private static let queue = DispatchQueue(
        label: "\(HarkLog.subsystem).process",
        qos: .utility,
        attributes: .concurrent)

    private static let logger = Logger(subsystem: HarkLog.subsystem, category: "process")

    public init() {}

    public func run(
        executable: URL,
        arguments: [String],
        timeout: Duration? = nil
    ) async throws(ProcessLaunchFailure) -> ProcessResult {
        let control = ProcessControl()
        let work = Task {
            await withCheckedContinuation { (continuation: CheckedContinuation<ProcessOutcome, Never>) in
                Self.queue.async {
                    continuation.resume(returning: Self.execute(executable, arguments, control))
                }
            }
        }
        // The watchdog only ever terminates the child; the outcome still comes back through `work`, so there is
        // no path where this returns while a process is still running.
        let watchdog = timeout.map { limit in
            Task {
                guard (try? await Task.sleep(for: limit)) != nil else { return }
                control.timeOut()
            }
        }
        let outcome = await work.value
        watchdog?.cancel()
        switch outcome {
        case .result(let result): return result
        case .failure(let failure): throw failure
        }
    }

    private static func execute(
        _ executable: URL,
        _ arguments: [String],
        _ control: ProcessControl
    ) -> ProcessOutcome {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let out = Pipe()
        let error = Pipe()
        process.standardOutput = out
        process.standardError = error
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            logger.error("\(executable.lastPathComponent, privacy: .public) did not start: \(error)")
            return .failure(.launch("\(executable.lastPathComponent): \(error.localizedDescription)"))
        }
        // Adopting after `run` is deliberate: terminating a process that has not launched is a no-op that would
        // let the watchdog report a timeout the child never had.
        guard control.adopt(process) else {
            process.terminate()
            process.waitUntilExit()
            return .failure(.timedOut)
        }

        let drained = DispatchGroup()
        let captured = OSAllocatedUnfairLock(initialState: (out: Data(), error: Data()))
        for (handle, isStandardOut) in [(out.fileHandleForReading, true), (error.fileHandleForReading, false)] {
            queue.async(group: drained) {
                let data = (try? handle.readToEnd()) ?? Data()
                captured.withLock { if isStandardOut { $0.out = data } else { $0.error = data } }
            }
        }
        process.waitUntilExit()
        drained.wait()

        if control.didTimeOut { return .failure(.timedOut) }
        let text = captured.withLock { $0 }
        return .result(
            ProcessResult(
                exitCode: process.terminationStatus,
                standardOutput: String(decoding: text.out, as: UTF8.self),
                standardError: String(decoding: text.error, as: UTF8.self)))
    }
}

private enum ProcessOutcome: Sendable {
    case result(ProcessResult)
    case failure(ProcessLaunchFailure)
}

/// Shared between the thread running the child and the watchdog that may kill it.
///
/// `Process` is not `Sendable`, hence `uncheckedState`: every touch of it happens under the lock, and the only
/// method the watchdog calls is `terminate()`.
private final class ProcessControl: Sendable {
    private struct State {
        var process: Process?
        var timedOut = false
    }

    private let state = OSAllocatedUnfairLock<State>(uncheckedState: State())

    /// False when the watchdog already fired, which means the caller should not let this child run.
    func adopt(_ process: Process) -> Bool {
        state.withLock { state in
            guard !state.timedOut else { return false }
            state.process = process
            return true
        }
    }

    func timeOut() {
        state.withLock { state in
            state.timedOut = true
            state.process?.terminate()
        }
    }

    var didTimeOut: Bool { state.withLock(\.timedOut) }
}
