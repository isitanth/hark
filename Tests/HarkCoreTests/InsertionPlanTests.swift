import Foundation
import HarkCore
import Testing

private typealias F = Fixture

struct ReadBackCase: Sendable, CustomTestStringConvertible {
    let name: String
    let text: String
    let report: AXInsertionReport
    let verdict: AXInsertionVerdict

    var testDescription: String { name }
}

private func state(_ location: Int?, _ length: Int?, count: Int?) -> AXTextState {
    AXTextState(selectionLocation: location, selectionLength: length, characterCount: count)
}

let readBackCases: [ReadBackCase] = [
    .init(name: "the set was refused", text: "hello", report: .refused, verdict: .absent),
    .init(
        name: "caret insert: count and caret both moved", text: "hello",
        report: .init(
            setSucceeded: true, before: state(0, 0, count: 3), after: state(5, 0, count: 8), readBack: "hello"),
        verdict: .confirmed),
    .init(
        name: "Chromium: success, and nothing changed", text: "hello",
        report: .init(setSucceeded: true, before: state(3, 0, count: 3), after: state(3, 0, count: 3), readBack: "abc"),
        verdict: .absent),
    .init(
        name: "a selection replaced by a longer text", text: "HELLO",
        report: .init(
            setSucceeded: true, before: state(0, 2, count: 23), after: state(5, 0, count: 26), readBack: "HELLO"),
        verdict: .confirmed),
    .init(
        name: "the field rewrote the quotes: the count still says it went in", text: "it's",
        report: .init(
            setSucceeded: true, before: state(0, 0, count: 0), after: state(4, 0, count: 4), readBack: "it’s"),
        verdict: .confirmed),
    .init(
        name: "the read-back matches what was already there, the count did not move", text: "the",
        report: .init(
            setSucceeded: true, before: state(0, 0, count: 12), after: state(0, 0, count: 12), readBack: "the"),
        verdict: .absent),
    .init(
        name: "emoji count as two UTF-16 units", text: "ok 😀",
        report: .init(
            setSucceeded: true, before: state(1, 0, count: 1), after: state(6, 0, count: 6), readBack: "ok 😀"),
        verdict: .confirmed),
    .init(
        name: "same-length replacement: the caret decides", text: "ab",
        report: .init(setSucceeded: true, before: state(4, 2, count: 9), after: state(6, 0, count: 9)),
        verdict: .confirmed),
    .init(
        name: "same-length replacement that did nothing", text: "ab",
        report: .init(setSucceeded: true, before: state(4, 2, count: 9), after: state(4, 2, count: 9)),
        verdict: .absent),
    .init(
        name: "no count, the caret moved past the text", text: "hello",
        report: .init(setSucceeded: true, before: state(2, 0, count: nil), after: state(7, 0, count: nil)),
        verdict: .confirmed),
    .init(
        name: "no count, the caret did not move", text: "hello",
        report: .init(setSucceeded: true, before: state(2, 0, count: nil), after: state(2, 0, count: nil)),
        verdict: .absent),
    .init(
        name: "the count moved by something else, the caret confirms", text: "hello",
        report: .init(setSucceeded: true, before: state(0, 0, count: 3), after: state(5, 0, count: 9)),
        verdict: .confirmed),
    .init(
        name: "only a read-back, matching", text: "hello",
        report: .init(setSucceeded: true, readBack: "hello"), verdict: .confirmed),
    .init(
        name: "only a read-back, different", text: "hello",
        report: .init(setSucceeded: true, readBack: "hel"), verdict: .absent),
    .init(
        name: "a field that answers nothing: the set's success stands", text: "hello",
        report: .init(setSucceeded: true), verdict: .unverified),
    .init(
        name: "a rewrite of a different length (\"...\" to \"…\"): something moved, so no paste", text: "wait...",
        report: .init(
            setSucceeded: true, before: state(2, 0, count: 10), after: state(7, 0, count: 15), readBack: "wait…x"),
        verdict: .unverified),
    .init(
        name: "the count moved and the caret is unknown, the read-back differs", text: "wait...",
        report: .init(setSucceeded: true, before: state(nil, nil, count: 10), after: state(nil, nil, count: 14)),
        verdict: .unverified),
    .init(
        name: "a set that timed out and shows nothing yet", text: "hello",
        report: .init(setSucceeded: false, timedOut: true, before: state(0, 0, count: 3), after: state(0, 0, count: 3)),
        verdict: .uncertain),
    .init(
        name: "a set that timed out and answers nothing", text: "hello",
        report: .init(setSucceeded: false, timedOut: true), verdict: .uncertain),
    .init(
        name: "a set that timed out but has landed", text: "hello",
        report: .init(setSucceeded: false, timedOut: true, before: state(0, 0, count: 3), after: state(5, 0, count: 8)),
        verdict: .confirmed),
]

@Suite(.timeLimit(.minutes(1)))
struct InsertionPlanTests {
    @Test(arguments: readBackCases)
    func readingTheFieldBack(_ scenario: ReadBackCase) {
        #expect(scenario.report.verdict(for: scenario.text) == scenario.verdict)
    }

    @Test(arguments: [
        ("hello", "hello"), ("hello\n", "hello"), ("hello\r\n\n", "hello"), ("\n", ""), ("a\nb\n", "a\nb"),
        ("trailing space ", "trailing space "),
    ])
    func trailingLineBreaksAreStripped(_ text: String, _ prepared: String) {
        #expect(TextInserter.prepared(text) == prepared)
    }

    private struct Rig {
        let accessibility = FakeAccessibility()
        let pasteboard: FakePasteboard
        let keystrokes: FakeKeystrokes
        let workspace = SwitchableWorkspace(F.mail)
        let clock = ManualClock()

        init() {
            pasteboard = FakePasteboard()
            keystrokes = FakeKeystrokes(target: pasteboard)
        }

        var inserter: TextInserter {
            TextInserter(
                accessibility: accessibility, pasteboard: pasteboard, keystrokes: keystrokes, workspace: workspace,
                clock: clock)
        }
    }

    private static let caretInsert = AXInsertionReport(
        setSucceeded: true, before: state(0, 0, count: 0), after: state(5, 0, count: 5), readBack: "hello")

    @Test func aConfirmedAXInsertionTouchesNeitherPasteboardNorKeyboard() async throws {
        let rig = Rig()
        rig.accessibility.set(report: Self.caretInsert)

        try await rig.inserter.insert("hello\n", plan: .axInsert, focus: F.focus, clipboardFallback: true)

        #expect(rig.accessibility.insertions.map(\.text) == ["hello"])
        #expect(rig.accessibility.insertions.map(\.pid) == [F.mail.processID])
        #expect(rig.pasteboard.writes.isEmpty && rig.keystrokes.posted.isEmpty)
    }

    @Test func anAXInsertionThatTimedOutGoesToTheClipboardNotThePaste() async {
        let rig = Rig()
        rig.accessibility.set(report: AXInsertionReport(setSucceeded: false, timedOut: true))

        await #expect(throws: PipelineFailure.insertionTimedOut) {
            try await rig.inserter.insert("hello", plan: .axInsert, focus: F.focus, clipboardFallback: true)
        }
        #expect(rig.pasteboard.writes.isEmpty && rig.keystrokes.posted.isEmpty)
    }

    @Test func anUnverifiedAXInsertionIsNotPastedAgain() async throws {
        let rig = Rig()
        rig.accessibility.set(report: AXInsertionReport(setSucceeded: true))

        try await rig.inserter.insert("hello", plan: .axInsert, focus: F.focus, clipboardFallback: true)

        #expect(rig.pasteboard.writes.isEmpty && rig.keystrokes.posted.isEmpty)
    }

    @Test func anAbsentAXInsertionFallsBackToPaste() async throws {
        let rig = Rig()
        rig.accessibility.set(report: .refused)

        try await rig.inserter.insert("hello", plan: .axInsert, focus: F.focus, clipboardFallback: true)

        #expect(rig.pasteboard.writes == [.init(text: "hello", markers: [PasteboardMarker.transient])])
        #expect(rig.keystrokes.posted == [.paste])
    }

    @Test(arguments: [InsertionPlan.axInsert, .paste])
    func focusThatMovedToAnotherAppIsFocusChanged(_ plan: InsertionPlan) async {
        let rig = Rig()
        rig.accessibility.set(report: Self.caretInsert)
        rig.workspace.switchTo(AppIdentity(bundleID: "com.apple.Notes", name: "Notes", processID: 777))

        await #expect(throws: PipelineFailure.focusChanged) {
            try await rig.inserter.insert("hello", plan: plan, focus: F.focus, clipboardFallback: true)
        }
        #expect(rig.accessibility.insertions.isEmpty && rig.pasteboard.writes.isEmpty)
    }

    @Test(arguments: [InsertionPlan.axInsert, .paste])
    func noKnownAppIsAFailedInsertion(_ plan: InsertionPlan) async {
        let rig = Rig()
        await #expect(throws: PipelineFailure.insertionFailed) {
            try await rig.inserter.insert(
                "hello", plan: plan, focus: FocusSnapshot(app: nil), clipboardFallback: true)
        }
        await #expect(throws: PipelineFailure.insertionFailed) {
            try await rig.inserter.insert("hello", plan: plan, focus: nil, clipboardFallback: true)
        }
    }

    @Test func textThatIsOnlyLineBreaksInsertsNothing() async throws {
        let rig = Rig()
        try await rig.inserter.insert("\n\n", plan: .paste, focus: F.focus, clipboardFallback: true)
        #expect(rig.pasteboard.writes.isEmpty && rig.keystrokes.posted.isEmpty)
    }
}
