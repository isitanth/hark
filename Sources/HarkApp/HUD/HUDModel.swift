import Foundation
import HarkCore
import Observation

/// What the recording HUD shows, apart from `AppModel`, so thirty redraws a second touch only the HUD's hosting view
/// and not the panel or the menu bar icon.
///
/// It computes nothing itself: the state is `HUDPresentation`'s, the bars `SpectrumBins`', the time `ElapsedTime`'s.
/// It runs one loop while the pipeline is capturing, reads the level and the spectrum's window from the capture
/// without an actor hop, and assigns only what changed.
@Observable
final class HUDModel {
    private(set) var state = HUDState.hidden
    /// The last state that was not hidden: what the panel draws, so a fade-out shows the last frame instead of a
    /// layout without its status line.
    private(set) var face = HUDState.listening(handsFree: false)
    private(set) var bars = SpectrumBins()
    private(set) var timerText = ElapsedTime.text(milliseconds: 0)
    /// The live text, newest words kept, or nil.
    private(set) var liveLine: String?
    /// The setting: off clears the line and drops what arrives.
    var liveText = false {
        didSet {
            guard liveText != oldValue else { return }
            line.follow(snapshot, enabled: liveText)
            syncLine()
        }
    }

    @ObservationIgnored private let level: any AudioLevelSource
    @ObservationIgnored private let audio: any AudioWindowSource
    @ObservationIgnored private let analyzer = SpectrumAnalyzer()
    @ObservationIgnored private var snapshot = PipelineSnapshot(phase: .idle)
    @ObservationIgnored private var lastLevel: LevelReading?
    @ObservationIgnored private var handsFree = false
    /// The utterance the loop runs for: a cancel followed at once by a press can reach here coalesced, as a new
    /// utterance still in `.capturing`, and it gets a fresh loop and fresh bars.
    @ObservationIgnored private var capturing: UtteranceID?
    @ObservationIgnored private var loop: Task<Void, Never>?
    /// `-HarkDebugPreview hud…`: a fixed state that snapshots do not move.
    @ObservationIgnored private var pinned = false
    @ObservationIgnored private var line = PartialLine()

    /// Characters on the live line: 244 pt at 12 pt. The plan's 44 overflowed in French when measured on screen
    /// ("… avant que tout le monde parte en week-end" was cut mid-word by the view); `.truncationMode(.head)` stays
    /// as the guard for wider glyphs.
    static let lineBudget = 40

    private static let tick = Duration.milliseconds(33)
    private static let silence = [Float](repeating: 0, count: SpectrumBins.count)

    init(level: any AudioLevelSource, audio: any AudioWindowSource) {
        self.level = level
        self.audio = audio
    }

    func update(_ snapshot: PipelineSnapshot) {
        guard !pinned else { return }
        self.snapshot = snapshot
        let utterance = snapshot.phase == .capturing ? snapshot.utterance?.id : nil
        if utterance != capturing {
            loop?.cancel()
            loop = nil
            capturing = utterance
            if utterance != nil { start() }
        }
        line.follow(snapshot, enabled: liveText)
        syncLine()
        refresh()
    }

    /// A partial result, shown only if it belongs to the utterance being captured (`PartialLine`).
    func show(_ result: PartialTranscription.Result) {
        guard !pinned else { return }
        line.accept(result, snapshot: snapshot, enabled: liveText)
        syncLine()
    }

    private func syncLine() {
        let next = line.text.map { HeadTruncation.fit($0, maxCharacters: Self.lineBudget) }
        if next != liveLine { liveLine = next }
    }

    /// `TriggerGate.isLatched`, from `HotkeyBridge` after every key event.
    func setLatched(_ latched: Bool) {
        guard !pinned, latched != handsFree else { return }
        handsFree = latched
        refresh()
    }

    private func refresh() {
        let next = HUDPresentation.state(snapshot, lastLevel: lastLevel, handsFree: handsFree)
        if next != state { state = next }
        if next != .hidden, next != face { face = next }
    }

    private func start() {
        bars.reset()
        lastLevel = nil
        timerText = ElapsedTime.text(milliseconds: 0)
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let model = self else { return }
                model.read()
                do {
                    try await Task.sleep(for: Self.tick, tolerance: .milliseconds(5))
                } catch {
                    return
                }
            }
        }
    }

    private func read() {
        if let reading = level.takeLevel() {
            lastLevel = reading
            let text = ElapsedTime.text(milliseconds: reading.durationMs)
            if text != timerText { timerText = text }
        }
        let window = audio.window(count: SpectrumBins.windowSize, at: .now)
        var next = bars
        next.push(levels: window.flatMap { analyzer?.levels($0) } ?? Self.silence)
        if next != bars { bars = next }
    }

    /// Pins a state for screenshots. The bars are a fixed spectrum shaped as a voice draws it: strongest in the low
    /// bands, falling off above, so the centre bars stand tallest.
    func pin(_ state: HUDState, time: String, line: String? = nil) {
        pinned = true
        loop?.cancel()
        loop = nil
        var bins = SpectrumBins()
        bins.push(levels: [0.8, 0.85, 0.72, 0.55, 0.42, 0.33, 0.22])
        bars = bins
        timerText = time
        liveLine = line.map { HeadTruncation.fit($0, maxCharacters: Self.lineBudget) }
        self.state = state
        face = state
    }
}
