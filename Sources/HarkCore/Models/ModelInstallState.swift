import Foundation

public struct DownloadProgress: Sendable, Equatable {
    public let receivedBytes: Int64
    /// The catalogue's declared size, not the server's `Content-Length`: it is known before the request.
    public let expectedBytes: Int64

    public static let zero = DownloadProgress(receivedBytes: 0, expectedBytes: 0)

    public init(receivedBytes: Int64, expectedBytes: Int64) {
        self.receivedBytes = receivedBytes
        self.expectedBytes = expectedBytes
    }

    /// Clamped to 0...1. A server that sends more than the catalogue declares must not push the bar past full.
    public var fraction: Double {
        guard expectedBytes > 0 else { return 0 }
        return min(1, max(0, Double(receivedBytes) / Double(expectedBytes)))
    }
}

public enum ModelInstallFailure: Error, Sendable, Equatable {
    case insufficientSpace(required: Int64, available: Int64)
    case checksumMismatch(expected: String, actual: String)
    /// A redirect left the allowed origin. The host is the one we refused to follow.
    case forbiddenOrigin(String)
    case http(Int)
    case transport(String)
    case extraction(Int32)
    case filesystem(String)
    /// A delete was refused: the Transcriber has this tier loaded and its weights are mapped.
    case inUse

    /// Stable value for the log, in the shape `PipelineFailure.code` uses.
    public var code: String {
        switch self {
        case .insufficientSpace(let required, let available): "insufficient_space:\(required):\(available)"
        case .checksumMismatch: "checksum_mismatch"
        case .forbiddenOrigin(let host): "forbidden_origin:\(host)"
        case .http(let status): "http:\(status)"
        case .transport: "transport"
        case .extraction(let exitCode): "extraction:\(exitCode)"
        case .filesystem: "filesystem"
        case .inUse: "in_use"
        }
    }
}

/// One tier's row in the Model tab.
///
/// `compilingCoreML` covers moving the extracted `.mlmodelc` onto the path whisper.cpp derives from the weights
/// (see `ModelInstallation.coreMLEncoderURL(for:)`). The Neural Engine's own specialisation happens later, on the
/// first decode, and is the Transcriber's business rather than the store's.
public enum ModelInstallState: Sendable, Equatable {
    case notInstalled
    case downloading(DownloadProgress)
    case paused(DownloadProgress)
    /// A partial download died with the process. The bytes are gone; the user has to start it again.
    case interrupted
    case verifying
    case extracting
    case compilingCoreML
    case installed
    case failed(ModelInstallFailure)
}

extension ModelInstallState {
    /// The payload-free identity of a state. Transitions are defined over this, so the table stays a pure table.
    public enum Phase: String, Sendable, CaseIterable {
        case notInstalled = "not_installed"
        case downloading
        case paused
        case interrupted
        case verifying
        case extracting
        case compilingCoreML = "compiling_coreml"
        case installed
        case failed
    }

    public var phase: Phase {
        switch self {
        case .notInstalled: .notInstalled
        case .downloading: .downloading
        case .paused: .paused
        case .interrupted: .interrupted
        case .verifying: .verifying
        case .extracting: .extracting
        case .compilingCoreML: .compilingCoreML
        case .installed: .installed
        case .failed: .failed
        }
    }

    /// Work is in flight. The row shows a spinner and the store refuses a second install for the same tier.
    public var isActive: Bool {
        switch phase {
        case .downloading, .verifying, .extracting, .compilingCoreML: true
        default: false
        }
    }

    /// The Download button is live.
    public var canStart: Bool {
        switch phase {
        case .notInstalled, .paused, .interrupted, .failed: true
        default: false
        }
    }

    public var progress: DownloadProgress? {
        switch self {
        case .downloading(let progress), .paused(let progress): progress
        default: nil
        }
    }

    public var failure: ModelInstallFailure? {
        if case .failed(let failure) = self { failure } else { nil }
    }

    public func canTransition(to next: ModelInstallState) -> Bool {
        Phase.canTransition(from: phase, to: next.phase)
    }
}

extension ModelInstallState.Phase {
    /// Everything reachable from `phase`. Cancel and delete both land on `notInstalled`, which is why every
    /// phase but itself can reach it.
    public var successors: Set<Self> {
        switch self {
        case .notInstalled: [.downloading, .failed]
        // Re-entering `downloading` is the 403 restart from the pinned URL. `interrupted` is the quit whose
        // cancel produced no resume data, which is indistinguishable from a crash by the time the user sees it.
        case .downloading: [.downloading, .paused, .interrupted, .verifying, .notInstalled, .failed]
        case .paused: [.downloading, .notInstalled, .failed]
        case .interrupted: [.downloading, .notInstalled, .failed]
        // A tier is two artefacts, so a verified weights file is followed by the encoder's download.
        case .verifying: [.downloading, .extracting, .installed, .notInstalled, .failed]
        case .extracting: [.compilingCoreML, .notInstalled, .failed]
        case .compilingCoreML: [.installed, .notInstalled, .failed]
        // Re-downloading over an install goes through delete, so that a half-written file never shadows a good one.
        case .installed: [.notInstalled]
        case .failed: [.downloading, .notInstalled]
        }
    }

    public static func canTransition(from: Self, to: Self) -> Bool {
        from.successors.contains(to)
    }
}

extension ModelInstallState {
    /// The row's state at launch, from what the models directory holds.
    ///
    /// The one rule that matters: this never returns `downloading`. A download resumes on a click and on nothing
    /// else, so a clean pause or quit reads `paused` and a killed process reads `interrupted`.
    public static func atLaunch(installed: Bool, resume: DownloadProgress?, stagedFile: Bool) -> ModelInstallState {
        if installed { return .installed }
        if let resume { return .paused(resume) }
        // A staged file with no `.resume` sidecar is a crash orphan. `ModelStore` has already deleted the bytes.
        if stagedFile { return .interrupted }
        return .notInstalled
    }
}
