import AVFoundation
import Foundation

enum AudioSignal {
    static func sine(frequency: Double = 440, amplitude: Float, sampleRate: Double, count: Int) -> [Float] {
        (0..<count).map { amplitude * Float(sin(2 * .pi * frequency * Double($0) / sampleRate)) }
    }

    /// `count` samples alternating between `+amplitude` and `-amplitude`: RMS equals the amplitude exactly.
    static func square(amplitude: Float, count: Int) -> [Float] {
        (0..<count).map { $0.isMultiple(of: 2) ? amplitude : -amplitude }
    }

    static func rms(_ samples: [Float]) -> Double {
        guard !samples.isEmpty else { return 0 }
        return (samples.reduce(0) { $0 + Double($1) * Double($1) } / Double(samples.count)).squareRoot()
    }

    static func zeroCrossings(_ samples: [Float]) -> Int {
        zip(samples, samples.dropFirst()).count(where: { ($0 < 0) != ($1 < 0) })
    }

    /// A buffer in `format` carrying `samples` on every channel.
    static func pcmBuffer(_ samples: [Float], format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(1, samples.count)))
        else { return nil }
        fill(buffer, with: samples[...])
        return buffer
    }

    /// Overwrites `buffer` with `samples` on every channel, the way the engine recycles a tap buffer.
    static func fill(_ buffer: AVAudioPCMBuffer, with samples: ArraySlice<Float>) {
        guard let channels = buffer.floatChannelData else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for channel in 0..<Int(buffer.format.channelCount) {
            for (index, sample) in samples.enumerated() {
                channels[channel][index] = sample
            }
        }
    }
}
