import HarkCore
import Testing

@Suite struct HealthStatusTests {
    /// The raw facts HarkApp feeds in, as one value so every combination can be enumerated.
    struct Inputs: Sendable, CustomTestStringConvertible {
        var configInvalid = false
        var modelLoaded = true
        var microphone = MicPermissionStatus.granted
        var accessibilityTrusted = true
        var accessibilityNeeded = true
        var notificationsDenied = false
        var llmUnreachable = false

        var status: HealthStatus {
            HealthStatus(
                configError: configInvalid ? ConfigError(.empty) : nil, modelLoaded: modelLoaded,
                microphone: microphone, accessibilityTrusted: accessibilityTrusted,
                accessibilityNeeded: accessibilityNeeded, notificationsDenied: notificationsDenied,
                llmUnreachable: llmUnreachable)
        }

        var testDescription: String {
            "config \(configInvalid ? "bad" : "ok"), model \(modelLoaded), mic \(microphone), "
                + "ax \(accessibilityTrusted), ax needed \(accessibilityNeeded), "
                + "notifications denied \(notificationsDenied), llm unreachable \(llmUnreachable)"
        }

        /// 2 x 2 x 3 x 2 x 2 x 2 x 2: every input that could change the answer.
        static let every: [Inputs] =
            [false, true].flatMap { config in
                [true, false].flatMap { model in
                    [MicPermissionStatus.granted, .denied, .undetermined].flatMap { microphone in
                        [true, false].flatMap { accessibility in
                            [true, false].flatMap { needed in
                                [false, true].flatMap { notifications in
                                    [false, true].map { llm in
                                        Inputs(
                                            configInvalid: config, modelLoaded: model, microphone: microphone,
                                            accessibilityTrusted: accessibility, accessibilityNeeded: needed,
                                            notificationsDenied: notifications, llmUnreachable: llm)
                                    }
                                }
                            }
                        }
                    }
                }
            }
    }

    @Test(arguments: [
        (HealthIssue.configInvalid, HealthSeverity.error),
        (.modelNotLoaded, .error),
        (.microphoneDenied, .error),
        (.accessibilityNotTrusted, .error),
        (.accessibilityOptional, .warning),
        (.notificationsDenied, .warning),
        (.llmUnreachable, .warning),
    ])
    func severity(_ issue: HealthIssue, _ expected: HealthSeverity) {
        #expect(issue.severity == expected)
    }

    @Test func theSeverityTableCoversEveryIssue() {
        let covered: Set<HealthIssue> = [
            .configInvalid, .modelNotLoaded, .microphoneDenied, .accessibilityNotTrusted, .accessibilityOptional,
            .notificationsDenied, .llmUnreachable,
        ]
        #expect(covered == Set(HealthIssue.allCases))
    }

    @Test func severitiesOrderOkBelowWarningBelowError() {
        #expect(HealthSeverity.ok < .warning)
        #expect(HealthSeverity.warning < .error)
        #expect(HealthSeverity.allCases.sorted() == [.ok, .warning, .error])
    }

    /// Written out, so a change in which fact raises which issue shows up here rather than being re-derived.
    @Test(arguments: [
        (Inputs(), [HealthIssue](), HealthSeverity.ok),
        (Inputs(microphone: .undetermined), [], .ok),
        (Inputs(notificationsDenied: true), [.notificationsDenied], .warning),
        (Inputs(llmUnreachable: true), [.llmUnreachable], .warning),
        (Inputs(notificationsDenied: true, llmUnreachable: true), [.notificationsDenied, .llmUnreachable], .warning),
        (Inputs(modelLoaded: false, llmUnreachable: true), [.modelNotLoaded, .llmUnreachable], .error),
        (Inputs(accessibilityTrusted: false), [.accessibilityNotTrusted], .error),
        (Inputs(accessibilityTrusted: false, accessibilityNeeded: false), [.accessibilityOptional], .warning),
        (Inputs(accessibilityNeeded: false), [], .ok),
        (
            Inputs(accessibilityTrusted: false, notificationsDenied: true),
            [.accessibilityNotTrusted, .notificationsDenied], .error
        ),
        (Inputs(configInvalid: true), [.configInvalid], .error),
        (Inputs(modelLoaded: false), [.modelNotLoaded], .error),
        (Inputs(microphone: .denied), [.microphoneDenied], .error),
        (
            Inputs(microphone: .denied, accessibilityTrusted: false, notificationsDenied: true),
            [.microphoneDenied, .accessibilityNotTrusted, .notificationsDenied], .error
        ),
        (
            Inputs(configInvalid: true, modelLoaded: false, microphone: .undetermined, accessibilityTrusted: false),
            [.configInvalid, .modelNotLoaded, .accessibilityNotTrusted], .error
        ),
        (
            Inputs(
                configInvalid: true, modelLoaded: false, microphone: .denied, accessibilityTrusted: false,
                notificationsDenied: true),
            [.configInvalid, .modelNotLoaded, .microphoneDenied, .accessibilityNotTrusted, .notificationsDenied],
            .error
        ),
    ])
    func issues(_ inputs: Inputs, _ expected: [HealthIssue], _ severity: HealthSeverity) {
        let status = inputs.status
        #expect(status.issues == expected)
        #expect(status.severity == severity)
        #expect(status.showsErrorIcon == (severity == .error))
    }

    @Test(arguments: Inputs.every)
    func everyCombination(_ inputs: Inputs) {
        let status = inputs.status
        let raised: Set<HealthIssue> = Set(
            [
                inputs.configInvalid ? HealthIssue.configInvalid : nil,
                inputs.modelLoaded ? nil : .modelNotLoaded,
                inputs.microphone == .denied ? .microphoneDenied : nil,
                inputs.accessibilityTrusted
                    ? nil : inputs.accessibilityNeeded ? .accessibilityNotTrusted : .accessibilityOptional,
                inputs.notificationsDenied ? .notificationsDenied : nil,
                inputs.llmUnreachable ? .llmUnreachable : nil,
            ].compactMap { $0 })
        let blocking =
            inputs.configInvalid || !inputs.modelLoaded || inputs.microphone == .denied
            || (!inputs.accessibilityTrusted && inputs.accessibilityNeeded)

        #expect(Set(status.issues) == raised)
        #expect(status.issues.count == raised.count)
        for issue in HealthIssue.allCases {
            #expect(status.contains(issue) == raised.contains(issue))
        }
        #expect(status.issues.map(\.severity) == status.issues.map(\.severity).sorted(by: >), "most severe first")
        for severity in HealthSeverity.allCases {
            let within = status.issues.filter { $0.severity == severity }
            #expect(within == HealthIssue.allCases.filter { $0.severity == severity && raised.contains($0) })
        }
        #expect(status.severity == (blocking ? .error : raised.isEmpty ? .ok : .warning))
        #expect(status.showsErrorIcon == blocking)
    }

    @Test func okIsTheStatusWithNothingWrong() {
        #expect(HealthStatus.ok == Inputs().status)
        #expect(HealthStatus.ok.issues.isEmpty)
        #expect(HealthStatus.ok.severity == .ok)
        #expect(!HealthStatus.ok.showsErrorIcon)
    }

    /// Only the idle icon turns red, only for an error, and a press in flight always shows what the pipeline is
    /// doing: a warning never costs the icon, and a standing error never hides a recording.
    @Test(arguments: PipelinePhase.allCases)
    func theIconShowsErrorOnlyWhenIdleWithAnError(_ phase: PipelinePhase) {
        let busy: MenuBarIconState? =
            switch phase {
            case .idle: nil
            case .capturing: .recording
            case .transcribing, .resolving, .confirming, .acting, .inserting, .copying, .asking: .transcribing
            }
        for inputs in Inputs.every {
            let health = inputs.status
            for armed in [false, true] {
                let icon = MenuBarIconState(phase: phase, isArmed: armed, health: health)
                let idle: MenuBarIconState = health.severity == .error ? .error : armed ? .armed : .idle
                #expect(icon == busy ?? idle, "\(inputs.testDescription), armed \(armed)")
            }
        }
    }

    @Test(arguments: [
        (HealthStatus.ok, MenuBarIconState.idle),
        (Inputs(notificationsDenied: true).status, .idle),
        (Inputs(accessibilityTrusted: false, notificationsDenied: true).status, .error),
        (Inputs(accessibilityTrusted: false, accessibilityNeeded: false).status, .idle),
        (Inputs(microphone: .undetermined).status, .idle),
        (Inputs(configInvalid: true).status, .error),
        (Inputs(modelLoaded: false, accessibilityTrusted: false).status, .error),
    ])
    func idleIcon(_ health: HealthStatus, _ expected: MenuBarIconState) {
        #expect(MenuBarIconState(phase: .idle, health: health) == expected)
        #expect(MenuBarIconState(phase: .capturing, health: health) == .recording)
        #expect(MenuBarIconState(phase: .transcribing, health: health) == .transcribing)
    }
}
