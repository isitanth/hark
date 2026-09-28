import AppKit
import ApplicationServices
import CryptoKit
import Foundation
import HarkCore
import Testing

/// M9.0 (a): what the Accessibility read of the selection returns, app by app, at the moment the Ask key would go
/// down (docs/acceptance/M9.md). Two ways to run it, both appending one JSON line per probe to HARK_TEST_AX_OUT:
///
///     HARK_TEST_AX_APP=com.apple.TextEdit HARK_TEST_AX_LABEL=textedit/selection \
///     HARK_TEST_AX_OUT=/path/to/out.jsonl swift test --filter SelectionReadLiveTests
///
/// probes that app once, set up beforehand; `HARK_TEST_AX_WATCH=<seconds>` instead probes whichever app is in front
/// every half second and writes a line each time what it finds changes, while a person selects text in their apps.
///
/// A probe makes the shipped read, `SystemAccessibility.selectedText(of:)`, twice 300 ms apart, since a Chromium app
/// may switch its tree on only after the first message, then the shipped focus probe that decides where text goes. It
/// also makes the same two messages itself to keep the AXError and the time that the shipped read folds into nil. The
/// selection's text is never written: only its length and the start of its SHA-256.
///
/// The test process runs under whatever launched `swift test`, so Accessibility is that app's grant, not Hark's.
/// The answer comes from the target app, and it is the same whoever asks.
@Suite(
    .enabled(
        if: ProcessInfo.processInfo.environment["HARK_TEST_AX_OUT"] != nil
            && (ProcessInfo.processInfo.environment["HARK_TEST_AX_APP"] != nil
                || ProcessInfo.processInfo.environment["HARK_TEST_AX_WATCH"] != nil)
    ),
    .serialized)
struct SelectionReadLiveTests {
    struct Read: Encodable, Equatable {
        let shipped: String?
        let shippedMs: Int
        let focusedError: Int32
        let focusedMs: Int
        let selectedError: Int32?
        let selectedMs: Int?
        let rangeLocation: Int?
        let rangeLength: Int?
        let characters: Int?
    }

    struct Line: Encodable {
        let label: String
        let second: Int
        let app: String
        let frontmost: Bool
        let trusted: Bool
        let embedsChromium: Bool
        let role: String?
        let subrole: String?
        let acceptsSelectedText: Bool?
        let valueSettable: Bool?
        let secureInput: Bool
        let kind: String
        let plan: String
        let reads: [Read]

        /// What a watch compares to decide whether the person did something new.
        var state: String {
            "\(app) \(role ?? "-") \(reads.last?.shipped ?? "nil") \(reads.last?.rangeLength ?? -1)"
        }
    }

    private static let environment = ProcessInfo.processInfo.environment

    @Test(.timeLimit(.minutes(15))) func readTheSelection() async throws {
        let path = try #require(Self.environment["HARK_TEST_AX_OUT"])
        let label = Self.environment["HARK_TEST_AX_LABEL"]
        if let bundleID = Self.environment["HARK_TEST_AX_APP"] {
            let running = try #require(
                NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
                "\(bundleID) is not running")
            try Self.append(await Self.probe(running, label: label ?? bundleID, second: 0), to: path)
            return
        }
        let seconds = try #require(Self.environment["HARK_TEST_AX_WATCH"].flatMap(Int.init))
        var last = ""
        for tick in 0..<(seconds * 2) {
            try await Task.sleep(for: .milliseconds(500))
            guard let pid = Self.frontmostPID(), let running = NSRunningApplication(processIdentifier: pid) else {
                continue
            }
            let line = await Self.probe(running, label: label ?? "watch", second: tick / 2)
            guard line.state != last else { continue }
            last = line.state
            try Self.append(line, to: path)
        }
    }

    private static func probe(_ running: NSRunningApplication, label: String, second: Int) async -> Line {
        let pid = running.processIdentifier
        let chromium = running.bundleURL.map {
            AppIdentity.embedsChromium(bundleURL: $0) { FileManager.default.fileExists(atPath: $0) }
        }
        let app = AppIdentity(
            bundleID: running.bundleIdentifier, name: running.localizedName, processID: pid,
            embedsChromium: chromium ?? false)
        let accessibility = SystemAccessibility()
        var reads: [Read] = []
        for attempt in 0..<2 {
            if attempt > 0 { try? await Task.sleep(for: .milliseconds(300)) }
            reads.append(await Self.read(pid, with: accessibility))
        }
        let element = await accessibility.focusedElement(of: pid)
        let secure =
            await accessibility.isSecureInputEnabled() || element?.subrole == FocusedElement.secureTextFieldSubrole
        let focus = FocusSnapshot(app: app, element: element, isSecureInput: secure)
        return Line(
            label: label, second: second, app: app.logName, frontmost: frontmostPID() == pid,
            trusted: await accessibility.isTrusted(), embedsChromium: app.embedsChromium, role: element?.role,
            subrole: element?.subrole, acceptsSelectedText: element?.acceptsSelectedText,
            valueSettable: element?.valueSettable, secureInput: secure, kind: "\(FocusResolver.kind(of: element))",
            plan: FocusResolver.pastePlan(focus: focus).map { "\($0)" } ?? "none", reads: reads)
    }

    /// The focused application as the Accessibility API sees it. NSWorkspace's answer only moves with a run loop,
    /// which a test process does not spin.
    private static func frontmostPID() -> Int32? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute as CFString, &value)
        guard status == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        var pid: pid_t = 0
        // Checked just above; the cast cannot fail.
        return AXUIElementGetPid(value as! AXUIElement, &pid) == .success ? pid : nil
    }

    private static func append(_ line: Line, to path: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        if !FileManager.default.fileExists(atPath: path) {
            try #require(FileManager.default.createFile(atPath: path, contents: nil))
        }
        let file = try #require(FileHandle(forWritingAtPath: path))
        defer { try? file.close() }
        try file.seekToEnd()
        try file.write(contentsOf: encoder.encode(line) + Data("\n".utf8))
    }
}

extension SelectionReadLiveTests {
    /// The shipped read, then the same two messages made here with their status and time kept.
    fileprivate static func read(_ pid: Int32, with accessibility: SystemAccessibility) async -> Read {
        let clock = ContinuousClock()
        var shipped: String?
        let shippedTime = await clock.measure { shipped = await accessibility.selectedText(of: pid) }

        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, SystemAccessibility.messagingTimeout)
        var focused: CFTypeRef?
        var focusedError = AXError.success
        let focusedTime = clock.measure {
            focusedError = AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused)
        }
        guard focusedError == .success, let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            return Read(
                shipped: describe(shipped), shippedMs: ms(shippedTime), focusedError: focusedError.rawValue,
                focusedMs: ms(focusedTime), selectedError: nil, selectedMs: nil, rangeLocation: nil, rangeLength: nil,
                characters: nil)
        }
        // Checked just above; the cast cannot fail.
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, SystemAccessibility.messagingTimeout)
        var selected: CFTypeRef?
        var selectedError = AXError.success
        let selectedTime = clock.measure {
            selectedError = AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selected)
        }
        var rangeValue: CFTypeRef?
        var range = CFRange()
        let hasRange =
            AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success
            && rangeValue.map { CFGetTypeID($0) == AXValueGetTypeID() } == true
            // Checked just above; the cast cannot fail.
            && AXValueGetValue(rangeValue as! AXValue, .cfRange, &range)
        var count: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(element, kAXNumberOfCharactersAttribute as CFString, &count)
        return Read(
            shipped: describe(shipped), shippedMs: ms(shippedTime), focusedError: focusedError.rawValue,
            focusedMs: ms(focusedTime), selectedError: selectedError.rawValue, selectedMs: ms(selectedTime),
            rangeLocation: hasRange ? range.location : nil, rangeLength: hasRange ? range.length : nil,
            characters: count as? Int)
    }

    /// Length and the start of the SHA-256, never the text: the selection stays off disk.
    fileprivate static func describe(_ text: String?) -> String? {
        guard let text else { return nil }
        let digest = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        return "len:\(text.count) sha:\(digest.prefix(10))"
    }

    fileprivate static func ms(_ duration: Duration) -> Int {
        Int(duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000)
    }
}
