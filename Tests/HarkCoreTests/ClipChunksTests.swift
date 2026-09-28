import Foundation
import HarkCore
import Testing

/// Where a long clip is cut before whisper sees it. A square wave stands in for speech: every 20 ms frame has the
/// same level, so the only quiet moments are the ones a test puts there.
@Suite struct ClipChunksTests {
    private static let rate = Int(SampleBuffer.sampleRate)
    private static let window = ClipChunks.maximumSampleCount

    private static func sound(_ seconds: Double, level: Float = 0.1) -> [Float] {
        AudioSignal.square(amplitude: level, count: Int(seconds * Double(rate)))
    }

    private static func silence(_ seconds: Double) -> [Float] {
        [Float](repeating: 0, count: Int(seconds * Double(rate)))
    }

    @Test(arguments: [0, 1, 16_000, ClipChunks.maximumSampleCount])
    func aClipThatFitsTheWindowIsOneChunk(_ count: Int) {
        #expect(ClipChunks.ranges(for: Self.sound(Double(count) / Double(Self.rate))) == [0..<count])
    }

    /// A 100 ms dip in steady sound, somewhere in the last 5 s before the mark: the cut lands in it.
    @Test(arguments: [25.5, 27.0, 29.8])
    func theCutLandsInTheQuietestMomentBeforeTheMark(_ seconds: Double) {
        var samples = Self.sound(40)
        let dip = Int(seconds * Double(Self.rate))..<Int(seconds * Double(Self.rate)) + 1_600
        for index in dip { samples[index] = 0 }

        let chunks = ClipChunks.ranges(for: samples)

        #expect(chunks.count == 2)
        #expect(dip.contains(chunks[0].upperBound), "cut at \(chunks[0].upperBound), dip \(dip)")
        #expect(chunks[1] == chunks[0].upperBound..<samples.count)
    }

    /// No quiet moment at all: the chunk still ends inside the window, as late as it can.
    @Test func steadySoundIsCutJustBeforeTheMark() {
        let chunks = ClipChunks.ranges(for: Self.sound(45))

        #expect(chunks.count == 2)
        #expect(chunks[0].lowerBound == 0)
        #expect(chunks[0].count <= Self.window && chunks[0].count > Self.window - ClipChunks.searchSampleCount)
    }

    /// Without a pause the chunks are back to back, in order, cover the clip and each fits whisper's window.
    @Test(arguments: [31.0, 61.0, 95.0, 150.0])
    func chunksCoverTheClipAndFitTheWindow(_ seconds: Double) {
        let samples = Self.sound(seconds)
        let chunks = ClipChunks.ranges(for: samples)

        #expect(chunks.first?.lowerBound == 0 && chunks.last?.upperBound == samples.count)
        #expect(zip(chunks, chunks.dropFirst()).allSatisfy { $0.upperBound == $1.lowerBound })
        #expect(chunks.allSatisfy { !$0.isEmpty && $0.count <= Self.window })
        #expect(chunks.count >= (samples.count + Self.window - 1) / Self.window)
    }

    /// A pause of 2 s or more ends the chunk, and its silence is left out, a quarter second kept on each side.
    @Test func aLongPauseEndsTheChunkAndIsSkipped() {
        let samples = Self.sound(10) + Self.silence(15) + Self.sound(20)

        #expect(ClipChunks.ranges(for: samples) == [0..<164_000, 396_000..<720_000])
    }

    /// Shorter than 2 s it is only a quiet moment, and it can be where the window is cut.
    @Test func aShortPauseDoesNotEndTheChunk() {
        let samples = Self.sound(10) + Self.silence(1.5) + Self.sound(28.5)

        let chunks = ClipChunks.ranges(for: samples)

        #expect(chunks.count == 2 && chunks[0].lowerBound == 0 && chunks[0].upperBound > 11 * Self.rate)
    }

    /// Silence at the start is skipped without a chunk of its own.
    @Test func aPauseThatOpensTheClipIsSkipped() {
        let chunks = ClipChunks.ranges(for: Self.silence(5) + Self.sound(30))

        #expect(chunks.first?.lowerBound == 76_000)
        #expect(chunks.count == 2)
    }

    /// Every 20 ms of sound lands in a chunk, whatever the pauses around it. The first two are what a review found
    /// dropped: a short word right before a pause at the start, and the end of a word cut just before the mark
    /// with a pause starting on it.
    private static let shapes: [[Float]] = [
        sound(0.19) + silence(3) + sound(40),
        sound(29.78) + silence(0.05) + sound(0.17) + silence(3) + sound(10),
        sound(10) + silence(15) + sound(20),
        silence(5) + sound(30) + silence(3) + sound(0.1) + silence(4),
        sound(45),
    ]

    @Test(arguments: shapes.indices)
    func everySoundLandsInAChunk(_ shape: Int) {
        let samples = Self.shapes[shape]
        let chunks = ClipChunks.ranges(for: samples)

        #expect(zip(chunks, chunks.dropFirst()).allSatisfy { $0.upperBound <= $1.lowerBound })
        #expect(chunks.allSatisfy { !$0.isEmpty && $0.count <= Self.window })
        var covered = [Bool](repeating: false, count: samples.count)
        for chunk in chunks { covered.replaceSubrange(chunk, with: repeatElement(true, count: chunk.count)) }
        let dropped = stride(from: 0, to: samples.count, by: 320).filter { frame in
            let span = frame..<min(frame + 320, samples.count)
            return ClipChunks.peakRMS(samples[span]) >= ClipChunks.quietRMS && !covered[span].allSatisfy { $0 }
        }
        #expect(dropped.isEmpty, "frames of sound outside every chunk: \(dropped.prefix(5))")
    }

    /// Nothing but silence past the window: only its last quarter second is left, which is too quiet to decode.
    @Test func silencePastTheWindowLeavesOnlyAQuietTail() {
        let chunks = ClipChunks.ranges(for: Self.silence(40))

        #expect(chunks == [636_000..<640_000])
        #expect(ClipChunks.peakRMS(Self.silence(40)[chunks[0]]) < ClipChunks.quietRMS)
    }

    private static let peaks: [([Float], Float)] = [
        ([Float](repeating: 0, count: 16_000), 0),
        (AudioSignal.square(amplitude: 0.2, count: 16_000), 0.2),
        ([Float](repeating: 0, count: 16_000) + [Float](repeating: 0.5, count: 320), 0.5),
        ([Float](repeating: 0, count: 320) + [Float](repeating: 0.3, count: 10), 0.3),
    ]

    @Test(arguments: peaks)
    func peakIsTheLoudestFrame(_ samples: [Float], _ expected: Float) {
        #expect(abs(ClipChunks.peakRMS(samples[...]) - expected) < 0.0001)
    }
}
