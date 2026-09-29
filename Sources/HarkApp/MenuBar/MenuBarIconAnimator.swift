import AppKit
import HarkCore
import Observation

/// Plays the menu bar icon's animations frame by frame, over the icon of the current state: the label redraws its image
/// on every frame, since SwiftUI's symbol effects are not reliable in a menu bar label. One plays at a time, and each
/// ends on the state's own icon. Nothing moves while Reduce Motion is on: the state's icon carries the meaning alone.
@Observable
final class MenuBarIconAnimator {
    /// The frame to draw over the state's icon; nil draws the icon as it is.
    private(set) var frame: MenuBarFrame?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var spinning = false

    /// Once: the trigger when a capture starts, the shake when an utterance failed.
    func play(_ animation: MenuBarAnimation) {
        spinning = false
        run { try await self.frames(of: animation) }
    }

    /// The bit turns while Hark works: after `spinDelay`, then a turn every `spinPeriod` until the work ends.
    func setWorking(_ working: Bool) {
        guard working != spinning else { return }
        spinning = working
        guard working else {
            stop()
            return
        }
        run {
            try await Task.sleep(for: MenuBarAnimation.spinDelay)
            // Reduce Motion turned on during a long answer stops the spin at the next turn.
            while !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                try await self.frames(of: .spin)
                try await Task.sleep(for: MenuBarAnimation.spinPeriod - MenuBarAnimation.spin.duration)
            }
        }
    }

    private func run(_ body: @escaping () async throws -> Void) {
        stop()
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        task = Task { try? await body() }
    }

    private func stop() {
        task?.cancel()
        task = nil
        frame = nil
    }

    /// Checks for cancellation before each frame, so a stopped animation never draws over the next one.
    private func frames(of animation: MenuBarAnimation) async throws {
        for frame in animation.frames {
            try Task.checkCancellation()
            self.frame = frame
            try await Task.sleep(for: frame.duration)
        }
        try Task.checkCancellation()
        frame = nil
    }
}
