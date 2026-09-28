import AVFoundation
import Foundation
import HarkCore
import Testing

@Suite struct WAVEncoderTests {
    private func ascii(_ data: Data, _ offset: Int) -> String {
        String(decoding: data[offset..<offset + 4], as: UTF8.self)
    }

    private func uint<T: FixedWidthInteger>(_ data: Data, _ offset: Int, as type: T.Type = T.self) -> T {
        data[offset..<offset + MemoryLayout<T>.size].reversed().reduce(0) { $0 << 8 | T($1) }
    }

    @Test func headerFieldsAtTheirOffsets() {
        let samples: [Float] = [0.5, -0.25, 1]
        let data = WAVEncoder.float32Mono(samples, sampleRate: 16_000)

        #expect(data.count == 58 + 12)
        #expect(ascii(data, 0) == "RIFF")
        #expect(uint(data, 4, as: UInt32.self) == UInt32(data.count - 8))
        #expect(ascii(data, 8) == "WAVE")
        #expect(ascii(data, 12) == "fmt ")
        #expect(uint(data, 16, as: UInt32.self) == 18)
        #expect(uint(data, 20, as: UInt16.self) == 3)
        #expect(uint(data, 22, as: UInt16.self) == 1)
        #expect(uint(data, 24, as: UInt32.self) == 16_000)
        #expect(uint(data, 28, as: UInt32.self) == 64_000)
        #expect(uint(data, 32, as: UInt16.self) == 4)
        #expect(uint(data, 34, as: UInt16.self) == 32)
        #expect(uint(data, 36, as: UInt16.self) == 0)
        #expect(ascii(data, 38) == "fact")
        #expect(uint(data, 42, as: UInt32.self) == 4)
        #expect(uint(data, 46, as: UInt32.self) == 3)
        #expect(ascii(data, 50) == "data")
        #expect(uint(data, 54, as: UInt32.self) == 12)
        #expect(
            [58, 62, 66].map { Float(bitPattern: uint(data, $0, as: UInt32.self)) } == samples)
    }

    @Test func emptyCaptureIsAHeaderOnly() {
        let data = WAVEncoder.float32Mono([], sampleRate: 16_000)
        #expect(data.count == 58)
        #expect(uint(data, 4, as: UInt32.self) == 50)
        #expect(uint(data, 46, as: UInt32.self) == 0)
        #expect(uint(data, 54, as: UInt32.self) == 0)
    }

    @Test func avAudioFileReadsItBack() throws {
        let directory = try TemporaryDirectory()
        let url = directory.url.appending(path: "hark-last.wav")
        let samples = AudioSignal.sine(amplitude: 0.4, sampleRate: 16_000, count: 4_000) + [1, -1, 0]
        try WAVEncoder.float32Mono(samples, sampleRate: 16_000).write(to: url)

        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        #expect(file.fileFormat.sampleRate == 16_000)
        #expect(file.fileFormat.channelCount == 1)
        #expect(file.fileFormat.commonFormat == .pcmFormatFloat32)
        #expect(file.length == AVAudioFramePosition(samples.count))

        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(samples.count)))
        try file.read(into: buffer)
        let channel = try #require(buffer.floatChannelData?[0])
        #expect(Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))) == samples)
    }
}
