import Foundation

public struct ProcessResult: Sendable, Equatable {
    public let exitCode: Int32
    public let standardOutput: String
    public let standardError: String

    public init(exitCode: Int32, standardOutput: String = "", standardError: String = "") {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
    }

    public var succeeded: Bool { exitCode == 0 }
}

public enum ProcessLaunchFailure: Error, Sendable, Equatable {
    /// The executable could not be started at all. The string is for the log, not for the user.
    case launch(String)
    case timedOut
}

/// Running an external binary. `ModelStore` uses it for `/usr/bin/ditto`; M6's `ActionRunner` will reuse it.
public protocol ProcessLaunching: Sendable {
    func run(
        executable: URL,
        arguments: [String],
        timeout: Duration?
    ) async throws(ProcessLaunchFailure) -> ProcessResult
}
