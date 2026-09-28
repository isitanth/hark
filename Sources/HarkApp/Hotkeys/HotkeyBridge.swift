import AppKit
import Foundation
import HarkCore
import KeyboardShortcuts
import os

extension KeyboardShortcuts.Name {
    /// Tap to start and tap again to stop; hold it instead and dictation ends when the key is let go.
    static let pushToTalk = Self("pushToTalk", initial: .init(.v, modifiers: [.control, .option]))
    static let cancelUtterance = Self("cancelUtterance", initial: .init(.escape, modifiers: [.control, .option]))
    /// Ask Hark about the selected text, or with nothing selected, the assistant. Tap or hold like the talk key.
    static let ask = Self("ask", initial: .init(.a, modifiers: [.control, .option]))
}

/// Drives the pipeline from the three shortcuts. The tap-or-hold decision is `TriggerGate` in HarkCore.
final class HotkeyBridge {
    /// M1 shipped F13 and F14, and KeyboardShortcuts writes an initial shortcut to defaults on first launch.
    /// This replaces those stored values once. A shortcut the user recorded is left alone.
    private static let migrationKey = "HarkTriggerDefaultsV2"

    private var listeners: [Task<Void, Never>] = []
    private static let logger = Logger(subsystem: "com.anthonychambet.hark", category: "hotkey")

    /// `onLatchChange` gets `TriggerGate.isLatched` after every key event: the HUD's lock beside the timer.
    /// `onAskDown` starts an ask from the Ask key: reading the selection needs the app, not the bridge.
    func start(
        driving controller: PipelineController, onAskDown: @escaping @MainActor () async -> Void,
        onLatchChange: @escaping @MainActor (Bool) -> Void, defaults: UserDefaults = .standard
    ) {
        guard listeners.isEmpty else { return }
        migrateInitialShortcuts(defaults)

        Self.logger.info(
            "listeners starting: pushToTalk = \(KeyboardShortcuts.getShortcut(for: .pushToTalk)?.description ?? "none", privacy: .public), cancel = \(KeyboardShortcuts.getShortcut(for: .cancelUtterance)?.description ?? "none", privacy: .public), ask = \(KeyboardShortcuts.getShortcut(for: .ask)?.description ?? "none", privacy: .public)"
        )
        listeners.append(
            Task {
                var gate = TriggerGate()
                for await event in KeyboardShortcuts.events(for: .pushToTalk) {
                    let key: TriggerGate.Key = event == .keyDown ? .down : .up
                    let intent = await controller.capturingIntent
                    let capturing = intent != nil
                    // Services › Ask Hark started this capture: a tap ends it, as Done does.
                    if intent?.isAsk == true, !gate.isLatched { gate.latch() }
                    let action = gate.handle(key, at: .now, isCapturing: capturing)
                    // Before the switch: the key-up that latches returns `.ignore`, whose branch is `continue`.
                    onLatchChange(gate.isLatched)
                    Self.logger.debug(
                        "event \(String(describing: event), privacy: .public), capturing \(capturing, privacy: .public) -> \(String(describing: action), privacy: .public)"
                    )
                    switch action {
                    case .start:
                        await controller.triggerDown()
                    case .stop:
                        await controller.triggerUp()
                    case .ignore:
                        continue
                    }
                }
            })
        listeners.append(
            Task {
                // A gate of its own: the talk key's latch never ends an ask this key started, nor the reverse.
                var gate = TriggerGate()
                for await event in KeyboardShortcuts.events(for: .ask) {
                    let key: TriggerGate.Key = event == .keyDown ? .down : .up
                    // Only an ask is this key's to end. Pressed during a dictation it starts a press of its own,
                    // which the pipeline logs as busy.
                    let capturing = await controller.capturingIntent?.isAsk == true
                    let action = gate.handle(key, at: .now, isCapturing: capturing)
                    Self.logger.debug(
                        "ask \(String(describing: event), privacy: .public), capturing \(capturing, privacy: .public) -> \(String(describing: action), privacy: .public)"
                    )
                    switch action {
                    case .start:
                        await onAskDown()
                    case .stop:
                        await controller.triggerUp()
                    case .ignore:
                        continue
                    }
                }
            })
        listeners.append(
            Task {
                for await event in KeyboardShortcuts.events(for: .cancelUtterance) where event == .keyDown {
                    await controller.cancel()
                }
            })
    }

    private func migrateInitialShortcuts(_ defaults: UserDefaults) {
        guard !defaults.bool(forKey: Self.migrationKey) else { return }
        defaults.set(true, forKey: Self.migrationKey)
        if KeyboardShortcuts.getShortcut(for: .pushToTalk) == .init(.f13) {
            KeyboardShortcuts.reset(.pushToTalk)
        }
        if KeyboardShortcuts.getShortcut(for: .cancelUtterance) == .init(.f14) {
            KeyboardShortcuts.reset(.cancelUtterance)
        }
    }
}
