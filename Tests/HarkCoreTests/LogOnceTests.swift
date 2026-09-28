import Foundation
import HarkCore
import Testing

/// A hand-written press sequence. Presses are numbered from 1; press n goes down at `start + n` seconds.
struct PressSequence: Sendable, CustomTestStringConvertible {
    let name: String
    let events: [PipelineEvent]
    /// Expected log lines, in order, as effect labels.
    let logs: [String]

    var testDescription: String { name }
}

private typealias F = Fixture

private func id(_ n: UInt64) -> UtteranceID { UtteranceID(n) }
private func down(_ n: UInt64) -> PipelineEvent { .triggerDown(id(n), at: F.pressedAt.addingTimeInterval(Double(n))) }
private func up(_ n: UInt64) -> PipelineEvent { .triggerUp(at: F.pressedAt.addingTimeInterval(Double(n) + 1.8)) }
private func focus(_ n: UInt64) -> PipelineEvent { .focusCaptured(id(n), F.focus) }
private func captured(_ n: UInt64, _ summary: CaptureSummary = F.speech) -> PipelineEvent { .captured(id(n), summary) }
private func heard(_ n: UInt64, _ text: String = "open finder") -> PipelineEvent {
    .transcribed(id(n), Transcript(raw: text), ms: 400)
}

let pressSequences: [PressSequence] = [
    .init(
        name: "one press, text to the clipboard",
        events: [
            down(1), focus(1), up(1), captured(1), heard(1), .resolved(id(1), normalized: nil, .copy(.chosen)),
            .copied(id(1)),
        ],
        logs: ["log:text_clipboard"]),
    .init(
        name: "second press while the first is transcribing",
        events: [
            down(1), focus(1), up(1), captured(1), down(2), up(2), heard(1),
            .resolved(id(1), normalized: nil, .copy(.chosen)), .copied(id(1)),
        ],
        logs: ["log:discarded:busy", "log:text_clipboard"]),
    .init(
        name: "two more presses while a command runs",
        events: [
            down(1), focus(1), up(1), captured(1), heard(1),
            .resolved(id(1), normalized: "open finder", .command(F.finder)),
            down(2), up(2), down(3), up(3), .actionFinished(id(1), exit: 0),
        ],
        logs: ["log:discarded:busy", "log:discarded:busy", "log:command"]),
    .init(
        name: "cancel while capturing, then late results",
        events: [down(1), .cancel, up(1), captured(1), heard(1), .failed(id(1), .deviceChanged), focus(1)],
        logs: ["log:discarded:cancelled"]),
    .init(
        name: "limit reached while the key is held, then release: the text so far goes through",
        events: [
            down(1), focus(1), .captureLimitReached(id(1)), up(1), captured(1, F.maxed), heard(1),
            .resolved(id(1), normalized: nil, .insert(.paste)), .inserted(id(1)),
        ],
        logs: ["log:text_inserted:max_duration"]),
    .init(
        name: "release and limit at the same moment: the stop's audio is what gets transcribed",
        events: [
            down(1), focus(1), up(1), .captureLimitReached(id(1)), captured(1, F.maxed), heard(1),
            .resolved(id(1), normalized: nil, .insert(.paste)), .inserted(id(1)),
        ],
        logs: ["log:text_inserted:max_duration"]),
    .init(
        name: "tap too short, stray transcript",
        events: [down(1), up(1), captured(1, F.short), heard(1)],
        logs: ["log:discarded:too_short"]),
    .init(
        name: "insertion fails, text still reaches the clipboard",
        events: [
            down(1), focus(1), up(1), captured(1), heard(1),
            .resolved(id(1), normalized: "open finder", .insert(.paste)),
            .failed(id(1), .insertionFailed), .copied(id(1)),
        ],
        logs: ["log:text_clipboard:insertion_failed"]),
    .init(
        name: "confirmed command exits non-zero",
        events: [
            down(1), focus(1), up(1), captured(1), heard(1, "ouvre le terminal"),
            .resolved(id(1), normalized: "ouvre le terminal", .command(F.guarded)), .confirmed(id(1), true),
            .focusRestored(id(1), true), .actionFinished(id(1), exit: 2), .actionFinished(id(1), exit: 0),
        ],
        logs: ["log:failed:action_exit"]),
    .init(
        name: "mic denied before the focus probe returns",
        events: [down(1), .failed(id(1), .micPermissionDenied), focus(1), up(1)],
        logs: ["log:failed:mic_permission_denied"]),
    .init(
        name: "two presses back to back",
        events: [
            down(1), focus(1), up(1), captured(1), .failed(id(1), .modelMissing(.small)),
            down(2), focus(2), up(2), captured(2), .failed(id(2), .modelMissing(.small)),
        ],
        logs: ["log:failed:model_missing:small", "log:failed:model_missing:small"]),
]

@Suite struct LogOnceTests {
    @Test(arguments: pressSequences + askPressSequences + assistPressSequences)
    func exactlyOneLinePerPress(_ sequence: PressSequence) {
        let reducer = PipelineReducer()
        var state = PipelineState.idle
        var records: [UtteranceRecord] = []
        var labels: [String] = []

        for event in sequence.events {
            // Rejected events are dropped, as PipelineController does.
            guard case .success(let transition) = reducer.reduce(state, event) else { continue }
            state = transition.state
            for effect in transition.effects {
                guard let record = effect.record else { continue }
                records.append(record)
                labels.append(effect.label)
            }
        }

        let presses = sequence.events.compactMap { event -> Date? in
            if case .triggerDown(_, let at, _) = event { at } else { nil }
        }
        #expect(state == .idle)
        #expect(labels == sequence.logs)
        #expect(Set(records.map(\.timestamp)) == Set(presses), "every press logs once, and only presses log")
        #expect(records.count == presses.count)
    }
}
