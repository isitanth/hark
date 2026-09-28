#if HARK_DEBUG_AUDIO
    import Foundation
    import os

    /// Compiled only with `scripts/bundle.sh --debug-audio`, and used only when launched with `-HarkDumpAudio YES`:
    /// the last utterance as a 16 kHz mono Float32 WAV that only the user can read.
    enum AudioDump {
        private static let logger = Logger(subsystem: HarkLog.subsystem, category: "audio-dump")

        static func save(_ samples: [Float], to url: URL) {
            let path = url.path(percentEncoded: false)
            unlink(path)
            let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
            guard fd >= 0 else {
                logger.error("cannot create \(path, privacy: .public): errno \(errno)")
                return
            }
            defer { close(fd) }
            let data = WAVEncoder.float32Mono(samples, sampleRate: 16_000)
            let written = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if written != data.count {
                logger.error("short write to \(path, privacy: .public): \(written) of \(data.count) bytes")
            }
        }
    }
#endif
