import Foundation
import HarkCore
import Testing

private typealias F = Fixture

/// Builds the record an utterance would have written, without running the pipeline.
private func record(
    _ outcome: PipelineOutcome, text: String? = "Hello there.", secure: Bool = false
) -> UtteranceRecord {
    let focus = FocusSnapshot(app: F.mail, isSecureInput: secure)
    let context = F.context(focus: focus, capture: F.speech, transcribeMs: 420)
    return UtteranceRecord(
        context: context, transcript: text.map { Transcript(raw: $0, normalized: $0.lowercased(), tier: .large) },
        outcome: outcome)
}

@Suite struct NotificationBodyTests {
    /// Clipboard-only mode: the clipboard is where the user asked the text to go.
    @Test func aCopyTheUserChoseIsAnnouncedWithItsFirstWords() {
        let content = ClipboardNotice.content(for: record(.textClipboard(.chosen)), style: .standard)
        #expect(content == .textCopied(preview: "Hello there.", fallback: false, sound: true))
    }

    @Test func aCopyAfterAFailedInsertionSaysSo() {
        let content = ClipboardNotice.content(
            for: record(.textClipboard(.fallback(.pasteNotConsumed))), style: .standard)
        #expect(content == .textCopied(preview: "Hello there.", fallback: true, sound: true))
    }

    /// The line the resolver caught names why, so the banner no longer needs the mode in force to tell.
    @Test func aCopyBecauseNothingTookTheTextAlsoSaysSo() {
        let content = ClipboardNotice.content(for: record(.textClipboard(.noTextField)), style: .standard)
        #expect(content == .textCopied(preview: "Hello there.", fallback: true, sound: true))
    }

    @Test func silentDropsTheSoundAndNothingElse() {
        let content = ClipboardNotice.content(for: record(.textClipboard(.chosen)), style: .silent)
        #expect(content == .textCopied(preview: "Hello there.", fallback: false, sound: false))
    }

    @Test func offSaysNothing() {
        #expect(ClipboardNotice.content(for: record(.textClipboard(.chosen)), style: .off) == nil)
    }

    /// The record of a password field carries no text at all, and neither does the notification.
    @Test func aPasswordFieldIsAnnouncedWithoutItsText() {
        let content = ClipboardNotice.content(
            for: record(.textClipboard(.secureField), text: "hunter2", secure: true), style: .standard)
        #expect(content == .textCopied(preview: nil, fallback: true, sound: true))
    }

    /// Clipboard-only mode copies a password field too: hidden, but where the user asked it to go.
    @Test func aPasswordFieldTheUserSentToTheClipboardIsNoFallback() {
        let content = ClipboardNotice.content(
            for: record(.textClipboard(.chosen), text: "hunter2", secure: true), style: .standard)
        #expect(content == .textCopied(preview: nil, fallback: false, sound: true))
    }

    /// Every other outcome has something on screen to show for it.
    @Test(arguments: [
        PipelineOutcome.textInserted, .command, .discarded(.clipboardFallbackDisabled), .failed(.pasteboardWrite),
    ])
    func nothingElseIsAnnounced(_ outcome: PipelineOutcome) {
        #expect(ClipboardNotice.content(for: record(outcome), style: .standard) == nil)
    }

    @Test func aShortTranscriptIsShownWhole() {
        #expect(ClipboardNotice.preview("Bonjour à tous.") == "Bonjour à tous.")
    }

    @Test func aLongTranscriptStopsAtFortyGraphemesAndSaysThereIsMore() {
        let long = String(repeating: "ab ", count: 40)
        let preview = ClipboardNotice.preview(long)
        #expect(preview.count == ClipboardNotice.previewLimit + 1)
        #expect(preview.hasSuffix("…"))
        #expect(long.hasPrefix(String(preview.dropLast())))
    }

    /// Graphemes, not UTF-16 units: forty emoji are forty characters, and none of them is cut in half.
    @Test func theLimitCountsWhatTheUserSees() {
        let flags = String(repeating: "🇫🇷", count: 41)
        let preview = ClipboardNotice.preview(flags)
        #expect(preview == String(repeating: "🇫🇷", count: ClipboardNotice.previewLimit) + "…")
    }

    @Test func lineBreaksAndRunsOfSpacesBecomeSingleSpaces() {
        #expect(ClipboardNotice.preview(" Deux\nlignes,  un  espace. ") == "Deux lignes, un espace.")
    }

    @Test func aTranscriptOfNothingButWhitespaceLeavesAnEmptyPreview() {
        #expect(ClipboardNotice.preview("   \n ") == "")
    }
}

/// Builds the record of a capture cut at the length limit.
private func cutRecord(_ outcome: PipelineOutcome, minutes: Int = 5) -> UtteranceRecord {
    let capture = CaptureSummary(durationMs: minutes * 60_000, peakRMS: 0.3, meanRMS: 0.05, reachedMaxDuration: true)
    return UtteranceRecord(
        context: F.context(capture: capture, transcribeMs: 2_400),
        transcript: Transcript(raw: "Hello there.", tier: .small), outcome: outcome)
}

@Suite struct CaptureLimitNoticeTests {
    @Test func textThatWentThroughCutAtTheLimitIsAnnounced() {
        let content = CaptureLimitNotice.content(for: cutRecord(.textInserted), style: .standard)
        #expect(content == .captureCut(minutes: 5, sound: true))
    }

    @Test func aCommandCutAtTheLimitIsAnnouncedToo() {
        let content = CaptureLimitNotice.content(for: cutRecord(.command), style: .silent)
        #expect(content == .captureCut(minutes: 5, sound: false))
    }

    /// The copy banner already says where the text is; a second banner would only repeat the duration.
    @Test func aCopyCutAtTheLimitLeavesItToTheCopyBanner() {
        #expect(CaptureLimitNotice.content(for: cutRecord(.textClipboard(.noTextField)), style: .standard) == nil)
    }

    @Test func nothingWhenNotificationsAreOffOrTheCaptureWasShorter() {
        #expect(CaptureLimitNotice.content(for: cutRecord(.textInserted), style: .off) == nil)
        #expect(CaptureLimitNotice.content(for: record(.textInserted), style: .standard) == nil)
    }
}

@Suite struct InputChangeNoticeTests {
    @Test(arguments: [(NotificationStyle.standard, true), (.silent, false)])
    func aRecordingCancelledByANewMicrophoneIsAnnounced(_ style: NotificationStyle, _ sound: Bool) {
        let content = InputChangeNotice.content(for: record(.failed(.deviceChanged), text: nil), style: style)
        #expect(content == .inputChanged(sound: sound))
    }

    @Test func nothingForAnotherFailureACancelOrWhenNotificationsAreOff() {
        #expect(InputChangeNotice.content(for: record(.failed(.deviceChanged), text: nil), style: .off) == nil)
        #expect(InputChangeNotice.content(for: record(.failed(.noInputDevice), text: nil), style: .standard) == nil)
        #expect(InputChangeNotice.content(for: record(.discarded(.cancelled), text: nil), style: .standard) == nil)
        #expect(InputChangeNotice.content(for: record(.textInserted), style: .standard) == nil)
    }
}

@Suite struct CommandFailureNoticeTests {
    @Test func anAppThatWasNotFoundIsAnnouncedWithItsName() {
        let content = CommandFailureNotice.content(
            for: record(.failed(.appNotFound("Safaro")), text: "ouvre Safaro"), style: .standard)
        #expect(content == .commandFailed(.appNotFound(name: "Safaro"), code: "app_not_found:Safaro", sound: true))
    }

    @Test func anAppThatQuitAtOnceIsAnnouncedSilentlyWhenAskedTo() {
        let content = CommandFailureNotice.content(
            for: record(.failed(.appExited("Notes")), text: "ouvre Notes"), style: .silent)
        #expect(content == .commandFailed(.appExited(name: "Notes"), code: "app_exited:Notes", sound: false))
    }

    @Test(arguments: [
        (PipelineFailure.actionTimeout, EntryOutcome.FailureReason.actionTimeout), (.actionLaunch, .actionLaunch),
    ])
    func anActionThatDidNotStartOrFinishIsAnnounced(_ failure: PipelineFailure, _ reason: EntryOutcome.FailureReason) {
        let content = CommandFailureNotice.content(for: record(.failed(failure)), style: .standard)
        #expect(content == .commandFailed(reason, code: failure.code, sound: true))
    }

    /// The app opened, behind the one in front: the command did what it said.
    @Test func anAppThatOpenedBehindIsNotAnnounced() {
        let failed = record(.failed(.appNotActivated("Mail")), text: "ouvre Mail")
        #expect(CommandFailureNotice.content(for: failed, style: .standard) == nil)
    }

    @Test func nothingForAnotherFailureACommandThatWorkedOrWhenNotificationsAreOff() {
        #expect(CommandFailureNotice.content(for: record(.failed(.appNotFound("Safaro"))), style: .off) == nil)
        #expect(CommandFailureNotice.content(for: record(.failed(.deviceChanged), text: nil), style: .standard) == nil)
        #expect(CommandFailureNotice.content(for: record(.command), style: .standard) == nil)
    }
}
