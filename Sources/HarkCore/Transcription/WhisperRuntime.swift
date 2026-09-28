import Darwin
import Foundation
import os
import whisper

public enum WhisperRuntime {
    public static func systemInfo() -> String {
        String(cString: whisper_print_system_info())
    }

    /// True when the Metal backend is compiled in. ggml reports it as "MTL :"; older builds said "METAL".
    public static var hasMetal: Bool {
        let info = systemInfo()
        return info.contains("MTL :") || info.contains("METAL")
    }

    /// Path of the image that provides the whisper symbols, as resolved by dyld.
    public static func libraryPath() -> String? {
        let symbol: @convention(c) () -> UnsafePointer<CChar>? = whisper_print_system_info
        var info = Dl_info()
        guard dladdr(unsafeBitCast(symbol, to: UnsafeRawPointer.self), &info) != 0, let path = info.dli_fname else {
            return nil
        }
        return String(cString: path)
    }

    /// Sends whisper's and ggml's own chatter to `os.Logger` instead of stderr. Idempotent.
    ///
    /// ggml prints a screenful of Metal device properties when the backend comes up and whisper prints the model
    /// header on every load. A menu bar app has no stderr anyone reads, and `Console.app` is where the rest of
    /// Hark's diagnostics already are. `whisper_log_set` forwards the callback to ggml as well, so one call covers
    /// both. ggml calls it from whichever thread it is on, so the callback may only touch the Logger, and it has
    /// to name `WhisperRuntime` in full: an implicit `Self.logger` would be a capture, and a C function pointer
    /// cannot be formed from a closure that captures.
    public static func redirectLogging() {
        let wasRedirected = redirected.withLock { flag in
            defer { flag = true }
            return flag
        }
        guard !wasRedirected else { return }
        whisper_log_set(
            { level, text, _ in
                guard let text else { return }
                let message = String(cString: text).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !message.isEmpty else { return }
                switch level {
                case GGML_LOG_LEVEL_ERROR: WhisperRuntime.logger.error("\(message, privacy: .public)")
                case GGML_LOG_LEVEL_WARN: WhisperRuntime.logger.warning("\(message, privacy: .public)")
                case GGML_LOG_LEVEL_INFO: WhisperRuntime.logger.info("\(message, privacy: .public)")
                default: WhisperRuntime.logger.debug("\(message, privacy: .public)")
                }
            }, nil)
    }

    static let logger = Logger(subsystem: HarkLog.subsystem, category: "whisper")
    private static let redirected = OSAllocatedUnfairLock(initialState: false)
}
