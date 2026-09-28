import Foundation
import HarkCore
import Testing

private typealias Phase = ModelInstallState.Phase

/// Every phase, with a state that carries a payload where one exists, so `phase` is exercised on real values.
private let sample: [Phase: ModelInstallState] = [
    .notInstalled: .notInstalled,
    .downloading: .downloading(DownloadProgress(receivedBytes: 10, expectedBytes: 100)),
    .paused: .paused(DownloadProgress(receivedBytes: 40, expectedBytes: 100)),
    .interrupted: .interrupted,
    .verifying: .verifying,
    .extracting: .extracting,
    .compilingCoreML: .compilingCoreML,
    .installed: .installed,
    .failed: .failed(.transport("lost the connection")),
]

/// The transition table, written out by hand rather than derived, so it is a second opinion on the source.
private let legal: [Phase: Set<String>] = [
    .notInstalled: ["downloading", "failed"],
    .downloading: ["downloading", "paused", "interrupted", "verifying", "not_installed", "failed"],
    .paused: ["downloading", "not_installed", "failed"],
    .interrupted: ["downloading", "not_installed", "failed"],
    .verifying: ["downloading", "extracting", "installed", "not_installed", "failed"],
    .extracting: ["compiling_coreml", "not_installed", "failed"],
    .compilingCoreML: ["installed", "not_installed", "failed"],
    .installed: ["not_installed"],
    .failed: ["downloading", "not_installed"],
]

@Suite struct ModelInstallStateTests {
    @Test func everyPhaseHasASampleAndReportsItself() {
        #expect(Set(sample.keys) == Set(Phase.allCases))
        for (phase, state) in sample {
            #expect(state.phase == phase)
        }
    }

    @Test func phaseNamesAreStableForTheLog() {
        #expect(
            Phase.allCases.map(\.rawValue) == [
                "not_installed", "downloading", "paused", "interrupted", "verifying", "extracting",
                "compiling_coreml", "installed", "failed",
            ])
    }

    @Test func theTransitionTableIsExactlyThis() {
        #expect(Set(legal.keys) == Set(Phase.allCases))
        for from in Phase.allCases {
            for to in Phase.allCases {
                let expected = legal[from]?.contains(to.rawValue) == true
                #expect(
                    Phase.canTransition(from: from, to: to) == expected,
                    "\(from.rawValue) -> \(to.rawValue)")
            }
        }
    }

    @Test func onlyADownloadReEntersItself() {
        for phase in Phase.allCases {
            #expect(Phase.canTransition(from: phase, to: phase) == (phase == .downloading))
        }
    }

    @Test func cancelAndDeleteReachNotInstalledFromAnywhere() {
        for phase in Phase.allCases where phase != .notInstalled {
            #expect(Phase.canTransition(from: phase, to: .notInstalled))
        }
        #expect(!Phase.canTransition(from: .notInstalled, to: .notInstalled))
    }

    @Test func installedIsOnlyLeftByDeleting() {
        #expect(Phase.installed.successors == [.notInstalled])
    }

    @Test func statesCompareThroughTheirPayload() {
        let state = sample[.downloading]
        #expect(state == .downloading(DownloadProgress(receivedBytes: 10, expectedBytes: 100)))
        #expect(state != .downloading(DownloadProgress(receivedBytes: 11, expectedBytes: 100)))
        #expect(ModelInstallState.downloading(.zero).canTransition(to: .verifying))
        #expect(!ModelInstallState.installed.canTransition(to: .verifying))
    }

    @Test func aRowIsEitherWorkingOrStartableOrDone() {
        for (phase, state) in sample {
            switch phase {
            case .downloading, .verifying, .extracting, .compilingCoreML:
                #expect(state.isActive)
                #expect(!state.canStart)
            case .notInstalled, .paused, .interrupted, .failed:
                #expect(!state.isActive)
                #expect(state.canStart)
            case .installed:
                #expect(!state.isActive)
                #expect(!state.canStart)
            }
        }
    }

    @Test func progressAndFailureAreReadableWithoutUnwrappingTheCase() {
        #expect(sample[.paused]?.progress?.receivedBytes == 40)
        #expect(sample[.downloading]?.progress?.fraction == 0.1)
        #expect(sample[.verifying]?.progress == nil)
        #expect(sample[.failed]?.failure == .transport("lost the connection"))
        #expect(sample[.installed]?.failure == nil)
    }

    @Test func fractionIsClampedAndSurvivesAnUnknownSize() {
        #expect(DownloadProgress.zero.fraction == 0)
        #expect(DownloadProgress(receivedBytes: 500, expectedBytes: 0).fraction == 0)
        #expect(DownloadProgress(receivedBytes: 500, expectedBytes: -1).fraction == 0)
        #expect(DownloadProgress(receivedBytes: 300, expectedBytes: 100).fraction == 1)
        #expect(DownloadProgress(receivedBytes: -5, expectedBytes: 100).fraction == 0)
        #expect(DownloadProgress(receivedBytes: 25, expectedBytes: 100).fraction == 0.25)
    }

    @Test func failureCodesAreStable() {
        let codes: [ModelInstallFailure] = [
            .insufficientSpace(required: 2, available: 1),
            .checksumMismatch(expected: "a", actual: "b"),
            .forbiddenOrigin("evil.example"),
            .http(403),
            .transport("timed out"),
            .extraction(2),
            .filesystem("read-only"),
        ]
        #expect(
            codes.map(\.code) == [
                "insufficient_space:2:1", "checksum_mismatch", "forbidden_origin:evil.example", "http:403",
                "transport", "extraction:2", "filesystem",
            ])
    }

    @Test(arguments: [false, true], [false, true])
    func aRelaunchNeverResumesOnItsOwn(_ stagedFile: Bool, _ installed: Bool) {
        let resumed = DownloadProgress(receivedBytes: 64, expectedBytes: 256)
        for resume in [nil, resumed] as [DownloadProgress?] {
            let state = ModelInstallState.atLaunch(installed: installed, resume: resume, stagedFile: stagedFile)
            #expect(state.phase != .downloading)
            #expect(!state.isActive)
        }
    }

    @Test func aCleanPauseSurvivesTheRelaunchAsPaused() {
        let resume = DownloadProgress(receivedBytes: 64, expectedBytes: 256)
        #expect(ModelInstallState.atLaunch(installed: false, resume: resume, stagedFile: false) == .paused(resume))
        #expect(ModelInstallState.atLaunch(installed: false, resume: resume, stagedFile: true) == .paused(resume))
    }

    @Test func aKilledProcessLeavesAnOrphanAndReadsInterrupted() {
        #expect(ModelInstallState.atLaunch(installed: false, resume: nil, stagedFile: true) == .interrupted)
        #expect(ModelInstallState.atLaunch(installed: false, resume: nil, stagedFile: false) == .notInstalled)
    }

    @Test func anInstalledModelOutranksAnythingLeftInStaging() {
        let resume = DownloadProgress(receivedBytes: 64, expectedBytes: 256)
        #expect(ModelInstallState.atLaunch(installed: true, resume: resume, stagedFile: true) == .installed)
        #expect(ModelInstallState.atLaunch(installed: true, resume: nil, stagedFile: true) == .installed)
    }
}
