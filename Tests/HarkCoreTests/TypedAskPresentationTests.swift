import Foundation
import HarkCore
import Testing

/// What the app reads of a typed ask (M15): the microphone is off, and the icon shows an ask being written.
@Suite struct TypedAskPresentationTests {
    private func capturing(_ input: AskInput) -> PipelineSnapshot {
        var context = UtteranceContext(
            id: UtteranceID(7), pressedAt: Date(timeIntervalSince1970: 0), intent: .assist(caller: nil))
        context.input = input
        return PipelineSnapshot(phase: .capturing, utterance: context)
    }

    @Test func aSpokenAskRecordsVoiceAndShowsCapturing() {
        #expect(capturing(.voice).isRecordingVoice)
        #expect(capturing(.voice).iconPhase == .capturing)
    }

    @Test func aTypedAskRecordsNothingAndShowsAnAsk() {
        #expect(!capturing(.typed).isRecordingVoice)
        #expect(capturing(.typed).iconPhase == .asking)
    }

    @Test(arguments: [PipelinePhase.idle, .transcribing, .asking])
    func outsideACaptureNothingIsRecorded(_ phase: PipelinePhase) {
        let snapshot = PipelineSnapshot(phase: phase)
        #expect(!snapshot.isRecordingVoice)
        #expect(snapshot.iconPhase == phase)
    }
}
