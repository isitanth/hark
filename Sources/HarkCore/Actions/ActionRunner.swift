import Foundation
import os

/// What running a command comes down to, decided before anything runs.
public enum ActionPlan: Sendable, Equatable {
    case openApplication(URL)
}

/// Pure: a command to its plan, or to the failure the log will carry. Every action type has a case here, so a new
/// one cannot be added without saying what it runs.
public enum ActionResolver {
    public static func plan(
        for command: ResolvedCommand, locator: ApplicationLocator
    ) -> Result<ActionPlan, PipelineFailure> {
        switch command.action {
        case .openApp:
            guard let url = locator.url(for: command.target) else { return .failure(.appNotFound(command.target)) }
            return .success(.openApplication(url))
        }
    }
}

/// Runs a command through the seams: `ActionResolver` decides, the workspace opens. Exit 0 is success: the app is in
/// front. An app that is not there is `app_not_found`, one the system would not open is `action_launch`, one that
/// opened behind the app in front is `app_not_activated`, since the command asked for it to be used, and one still
/// opening at the deadline — LaunchServices waiting on a first-launch prompt, say — is `action_timeout`, so the
/// pipeline always leaves `acting`.
public struct ActionRunner: ActionRunning {
    public static let defaultDeadline = Duration.seconds(15)

    private let workspace: any Workspace
    private let locator: ApplicationLocator
    private let deadline: Duration
    private let clock: any Clock<Duration>

    private static let logger = Logger(subsystem: HarkLog.subsystem, category: "actions")

    public init(
        workspace: any Workspace, locator: ApplicationLocator = ApplicationLocator(),
        deadline: Duration = ActionRunner.defaultDeadline, clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.workspace = workspace
        self.locator = locator
        self.deadline = deadline
        self.clock = clock
    }

    public func run(_ command: ResolvedCommand) async throws(PipelineFailure) -> Int32 {
        let plan: ActionPlan
        switch ActionResolver.plan(for: command, locator: locator) {
        case .success(let resolved):
            plan = resolved
        case .failure(let failure):
            Self.logger.error("\(command.id, privacy: .public): \(failure.code, privacy: .public)")
            throw failure
        }
        switch plan {
        case .openApplication(let url):
            let path = ApplicationLocator.path(of: url)
            let workspace = self.workspace
            guard
                let opening = await Deadline.first(
                    of: { await workspace.openApplication(at: url) }, within: deadline, clock: clock)
            else {
                Self.logger.error("\(command.id, privacy: .public): \(path, privacy: .public) still opening")
                throw .actionTimeout
            }
            switch opening {
            case .frontmost:
                Self.logger.info("\(command.id, privacy: .public): opened \(path, privacy: .public)")
                return 0
            case .behind:
                Self.logger.error("\(command.id, privacy: .public): \(path, privacy: .public) opened behind")
                throw .appNotActivated(command.target)
            case .exited:
                Self.logger.error(
                    "\(command.id, privacy: .public): \(path, privacy: .public) quit as soon as it opened")
                throw .appExited(command.target)
            case .refused:
                Self.logger.error("\(command.id, privacy: .public): the system did not open \(path, privacy: .public)")
                throw .actionLaunch
            }
        }
    }
}
