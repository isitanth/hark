import AVFoundation
import AppKit
import ApplicationServices
import Foundation
import HarkCore
import KeyboardShortcuts
import os

/// `Hark --self-test`: verifies the packaged app from the inside and exits.
/// `scripts/bundle.sh` runs it after signing. It never prompts, records or writes outside a temp directory.
enum SelfTest {
    static let flag = "--self-test"

    static func run() -> Never {
        Task {
            let report = Report()
            report.bundles()
            report.strings()
            report.config()
            report.icons()
            report.appIcon()
            report.whisper()
            report.permissions()
            report.audioDevices()
            await report.insertion()
            await report.pasteboard()
            await report.pipeline()
            FileHandle.standardOutput.write(Data(report.text.utf8))
            exit(report.failures == 0 ? 0 : 1)
        }
        dispatchMain()
    }
}

private final class Report {
    private(set) var text = ""
    private(set) var failures = 0

    private let resources = Bundle.main.resourceURL?.standardizedFileURL.path ?? "<none>"
    private let frameworks = Bundle.main.privateFrameworksURL?.standardizedFileURL.path ?? "<none>"

    func check(_ name: String, _ passed: Bool, _ detail: String) {
        if !passed { failures += 1 }
        text += "\(passed ? "PASS" : "FAIL")  \(name.padding(toLength: 24, withPad: " ", startingAt: 0)) \(detail)\n"
    }

    func info(_ name: String, _ detail: String) {
        text += "INFO  \(name.padding(toLength: 24, withPad: " ", startingAt: 0)) \(detail)\n"
    }

    func bundles() {
        let app = Bundle.module.bundleURL.standardizedFileURL.path
        check("bundle.HarkApp", app.hasPrefix(resources), app)

        let core = BundledResources.defaultCommands?.standardizedFileURL.path ?? "<missing>"
        check("bundle.HarkCore", core.hasPrefix(resources), core)

        // Shortcut.description reads "space_key" through KeyboardShortcuts' own Bundle.module,
        // which traps if the bundle is not found.
        let space = KeyboardShortcuts.Shortcut(.space).description
        let ks = Bundle.main.url(forResource: "KeyboardShortcuts_KeyboardShortcuts", withExtension: "bundle")
        check("bundle.KeyboardShortcuts", ks != nil && space != "Space_Key", "\(space) from \(ks?.path ?? "<missing>")")
    }

    func strings() {
        let key = "panel.quit"
        let en = localized(key, in: Bundle.module, language: "en")
        let fr = localized(key, in: Bundle.module, language: "fr")
        check("strings.en", en != nil && en != key, en ?? "<missing>")
        check("strings.fr", fr != nil && fr != key && fr != en, fr ?? "<missing>")
        info(
            "strings.current",
            "\(String(localized: L("panel.quit"))) [\(Bundle.module.preferredLocalizations.joined(separator: ","))]")

        let enKeys = tableKeys(in: Bundle.module, language: "en")
        let frKeys = tableKeys(in: Bundle.module, language: "fr")
        check(
            "strings.catalog", !enKeys.isEmpty && enKeys == frKeys,
            "\(enKeys.count) en keys, \(frKeys.count) fr keys, same set: \(enKeys == frKeys)")

        // A positional format string, which the catalog's plain keys never exercise.
        let location = String(
            format: localized("config.location %lld %lld", in: Bundle.module, language: "fr") ?? "", 12, 5)
        check("strings.format.fr", location == "Ligne 12, colonne 5", location)

        let plistFR = Bundle.main.url(
            forResource: "InfoPlist", withExtension: "strings", subdirectory: nil, localization: "fr")
        check("strings.InfoPlist.fr", plistFR != nil, plistFR?.path ?? "<missing>")
    }

    /// The file a first launch copies into Application Support must parse inside the signed app, every app it names
    /// must be on this Mac, and the matcher must tell a command from a sentence with it.
    func config() {
        guard let url = BundledResources.defaultCommands, let data = try? Data(contentsOf: url) else {
            check("config.default", false, "<missing default-commands.yaml>")
            return
        }
        let config: CommandConfig
        do throws(ConfigError) {
            config = try CommandConfig.parse(data)
        } catch {
            check("config.default", false, error.description)
            return
        }
        check(
            "config.default", !config.commands.isEmpty, "\(config.commands.count) commands in \(url.lastPathComponent)")

        let locator = ApplicationLocator()
        let missing = config.commands.filter { locator.url(for: $0.app) == nil }.map(\.app)
        check(
            "commands.apps", missing.isEmpty,
            missing.isEmpty ? "all \(config.commands.count) found" : "not found: \(missing.joined(separator: ", "))")

        let matcher = CommandMatcher(config: config)
        for (said, id) in [("Ouvre le Finder.", "open_finder"), ("Finder is slow today.", nil)] as [(String, String?)] {
            let heard = matcher.match(Normalizer.normalize(said))?.command.id
            check(id == nil ? "commands.text" : "commands.match", heard == id, "\(said) -> \(heard ?? "text")")
        }
    }

    func whisper() {
        let path =
            WhisperRuntime.libraryPath().map { URL(fileURLWithPath: $0).standardizedFileURL.path } ?? "<unresolved>"
        check("whisper.load", path.hasPrefix(frameworks), path)
        let system = WhisperRuntime.systemInfo()
        check("whisper.metal", WhisperRuntime.hasMetal, system)
    }

    func permissions() {
        let mic: String
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: mic = "authorized"
        case .denied: mic = "denied"
        case .restricted: mic = "restricted"
        case .notDetermined: mic = "notDetermined"
        @unknown default: mic = "unknown"
        }
        info("tcc.microphone", mic)
        info("tcc.accessibility", AXIsProcessTrusted() ? "trusted" : "untrusted")
    }

    /// Lists input devices through the HAL. Never touches AVAudioEngine, so it cannot open the microphone.
    func audioDevices() {
        let devices = AudioDevices.inputDevices()
        let systemDefault = AudioDevices.defaultInputDeviceID()
        for device in devices {
            let marker = device.id == systemDefault ? " (system default)" : ""
            info("audio.device", "\(device.name) [\(device.transport.rawValue)]\(marker)")
        }
        let choice = InputDevicePolicy().choose(from: devices, systemDefault: systemDefault, mode: .pushToTalk)
        check("audio.pushToTalkInput", choice != nil, choice?.device.name ?? "<no input device>")
    }

    /// Resolves ⌘V on the layout in use and reads the frontmost app's focused element. Posts nothing, writes nothing.
    func insertion() async {
        let code = KeyLayoutMap.current()?.keyCode(for: "v", modifiers: .command)
        check("insertion.pasteKey", code != nil, "⌘V is key code \(code.map(String.init) ?? "<none>")")
        guard let front = NSWorkspace.shared.frontmostApplication else {
            info("insertion.focus", "no frontmost app")
            return
        }
        let accessibility = SystemAccessibility()
        let element = await accessibility.focusedElement(of: front.processIdentifier)
        let chromium = front.bundleURL.map {
            AppIdentity.embedsChromium(bundleURL: $0, exists: FileManager.default.fileExists)
        }
        info(
            "insertion.focus",
            "\(front.bundleIdentifier ?? "?") role \(element?.role ?? "<none>"), "
                + "selected text settable \(element?.acceptsSelectedText ?? false), chromium \(chromium ?? false)")
        // What a second dictation into that field would land after, and whether it would gain a space.
        let before = await accessibility.characterBeforeInsertion(of: front.processIdentifier)
        let spaced = InsertionSpacing.needsSpace(after: before, before: "dictated")
        info(
            "insertion.caret",
            "character before \(before.map { "\"\($0)\"" } ?? "<none>"), leading space \(spaced)")
    }

    /// Snapshot and restore on a private pasteboard, so the user's clipboard is never touched: two items, one with
    /// two types, survive a transient write, and a write made after the paste blocks the restore.
    func pasteboard() async {
        let board = NSPasteboard(name: NSPasteboard.Name("com.anthonychambet.hark.self-test"))
        defer { board.releaseGlobally() }
        board.clearContents()
        let first = NSPasteboardItem()
        first.setString("first", forType: .string)
        first.setData(Data("<b>first</b>".utf8), forType: .html)
        let second = NSPasteboardItem()
        second.setString("second", forType: .string)
        board.writeObjects([first, second])

        let facade = AppKitPasteboard(board)
        let before = await facade.snapshot()
        let written = await facade.write("dictated", markers: [PasteboardMarker.transient])
        let held = board.string(forType: .string)
        let transient = board.types?.contains(NSPasteboard.PasteboardType(PasteboardMarker.transient)) ?? false
        let restored = await facade.restore(before, ifChangeCountIs: written ?? -1)
        let after = await facade.snapshot()
        check(
            "pasteboard.roundTrip",
            written != nil && held == "dictated" && transient && restored && after.items == before.items,
            "\(before.items.count) items, \(before.items.map(\.representations.count)) types, restored \(restored)")

        let again = await facade.write("dictated", markers: [])
        board.clearContents()
        board.setString("user copy", forType: .string)
        let blocked = await facade.restore(before, ifChangeCountIs: again ?? -1)
        check(
            "pasteboard.keepsUserCopy", !blocked && board.string(forType: .string) == "user copy",
            "restore refused: \(!blocked)")

        // The paste's promise: nothing is produced until a reader asks, and the asking is what the paste waits for.
        let reads = OSAllocatedUnfairLock(initialState: 0)
        let promised = await facade.promise("dictated", markers: [PasteboardMarker.transient]) {
            reads.withLock { $0 += 1 }
        }
        let beforeRead = reads.withLock { $0 }
        let taken = board.string(forType: .string)
        _ = board.string(forType: .string)
        let afterRead = reads.withLock { $0 }
        check(
            "pasteboard.promise", promised != nil && beforeRead == 0 && taken == "dictated" && afterRead == 1,
            "reads before \(beforeRead), after two reads \(afterRead), text \(taken ?? "<none>")")
    }

    /// Drives one synthetic press through PipelineController with the real @MainActor AppKitWorkspace.
    /// NullTranscriptionEngine ends it, so nothing reaches the pasteboard. The log goes to a temp directory.
    func pipeline() async {
        let directory = FileManager.default.temporaryDirectory.appending(path: "hark-self-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let log = UtteranceLog(directory: directory)
        let environment = PipelineEnvironment(
            workspace: AppKitWorkspace(), pasteboard: AppKitPasteboard(), audio: SyntheticAudioInput())
        let controller = PipelineController(environment: environment, log: log)
        var snapshots = controller.snapshots.makeAsyncIterator()

        let expected = NSWorkspace.shared.frontmostApplication.map {
            AppIdentity(bundleID: $0.bundleIdentifier, name: $0.localizedName, processID: $0.processIdentifier).logName
        }
        await controller.triggerDown()
        while let snapshot = await snapshots.next(), snapshot.utterance?.focus == nil {}
        await controller.triggerUp()
        var record: UtteranceRecord?
        while record == nil, let snapshot = await snapshots.next() {
            if snapshot.phase == .idle { record = snapshot.lastRecord }
        }

        let lines =
            (try? String(contentsOf: log.fileURL(for: record?.timestamp ?? Date()), encoding: .utf8))?
            .split(separator: "\n") ?? []
        check(
            "pipeline.mainActorSeam", record?.targetApp == expected && expected != nil,
            "target_app \(record?.targetApp ?? "<none>") via AppKitWorkspace")
        check(
            "pipeline.logOnce", lines.count == 1 && record?.error == "model_missing:small",
            String(lines.first ?? "<none>"))
        let keys = lines.first
            .flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
            .map { Set($0.keys) }
        check(
            "pipeline.logKeys", keys == Set(UtteranceRecord.keys) && UtteranceRecord.keys.count == 11,
            "\(keys?.count ?? 0) keys, model_tier \(record?.modelTier?.rawValue ?? "null")")
    }

    func icons() {
        for state in MenuBarIconState.allCases {
            let image = MenuBarIconRenderer.image(for: state)
            let ink = inkSize(image)
            let size = "\(Int(image.size.width))x\(Int(image.size.height)) pt"
            check(
                "icon.\(state.rawValue)", image.size == MenuBarIconRenderer.size && image.isTemplate && ink != nil,
                "\(state.symbolName), \(size), template \(image.isTemplate), ink \(ink ?? "none") at 2x")
        }
    }

    /// The .icns generated by bundle.sh from Support/Icon/AppIcon.png.
    func appIcon() {
        let url = Bundle.main.url(forResource: "Hark", withExtension: "icns")
        let representations = url.flatMap { NSImage(contentsOf: $0)?.representations.count } ?? 0
        check(
            "icon.appIcon", representations >= 10,
            "\(url?.lastPathComponent ?? "<missing>"), \(representations) representations")
    }

    /// Bounding box of the drawn pixels when rendered at 2x, as "WxH".
    private func inkSize(_ image: NSImage) -> String? {
        let side = Int(MenuBarIconRenderer.size.width) * 2
        guard
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()

        var xs: [Int] = []
        var ys: [Int] = []
        for y in 0..<side {
            for x in 0..<side where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05 {
                xs.append(x)
                ys.append(y)
            }
        }
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return nil }
        return "\(maxX - minX + 1)x\(maxY - minY + 1)"
    }

    private func tableKeys(in bundle: Bundle, language: String) -> Set<String> {
        guard
            let url = bundle.url(
                forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: language),
            let table = NSDictionary(contentsOf: url) as? [String: String]
        else { return [] }
        return Set(table.keys)
    }

    private func localized(_ key: String, in bundle: Bundle, language: String) -> String? {
        guard let path = bundle.path(forResource: language, ofType: "lproj"), let lproj = Bundle(path: path) else {
            return nil
        }
        return lproj.localizedString(forKey: key, value: nil, table: "Localizable")
    }
}

private struct SyntheticAudioInput: AudioInput {
    let events = AsyncStream<AudioInputEvent> { $0.finish() }

    func start(_ id: UtteranceID) async throws(PipelineFailure) {}

    func stop(_ id: UtteranceID) async throws(PipelineFailure) -> CapturedAudio {
        CapturedAudio(
            summary: CaptureSummary(durationMs: 1000, peakRMS: 0.2, meanRMS: 0.05),
            samples: [Float](repeating: 0, count: 16_000))
    }

    func cancel(_ id: UtteranceID) async {}
}
