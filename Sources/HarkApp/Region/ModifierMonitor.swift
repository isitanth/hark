import AppKit
import CoreGraphics

/// Whether ⌃ and ⌥ are both down, whatever else is, while an ask's capture runs. The Ask panel is key then, so the
/// modifiers reach Hark and a local monitor sees them; a global one covers a moment when another window has the
/// keyboard; one read of the live state when the capture starts catches keys already held (the shipped ⌃⌥A arms
/// framing for its whole hold). Nothing is watched outside an ask's capture, so ⌃-click and ⌃⌥ drags stay the other
/// apps' everywhere else.
final class ModifierMonitor {
    var onChange: ((Bool) -> Void)?
    private(set) var armed = false
    private var local: Any?
    private var global: Any?

    func start() {
        guard local == nil else { return }
        local = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.evaluate(event.modifierFlags)
            return event
        }
        global = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.evaluate(event.modifierFlags)
        }
        let held = CGEventSource.flagsState(.combinedSessionState)
        evaluate(control: held.contains(.maskControl), option: held.contains(.maskAlternate))
    }

    /// The capture ended: framing disarms at once.
    func stop() {
        if let local { NSEvent.removeMonitor(local) }
        if let global { NSEvent.removeMonitor(global) }
        local = nil
        global = nil
        set(false)
    }

    private func evaluate(_ flags: NSEvent.ModifierFlags) {
        evaluate(control: flags.contains(.control), option: flags.contains(.option))
    }

    private func evaluate(control: Bool, option: Bool) {
        set(control && option)
    }

    private func set(_ armed: Bool) {
        guard armed != self.armed else { return }
        self.armed = armed
        onChange?(armed)
    }
}
