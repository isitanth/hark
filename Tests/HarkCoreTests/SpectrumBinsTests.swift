import Foundation
import HarkCore
import Testing

@Suite struct SpectrumBinsTests {
    /// 100 · 60^(b / 7), to the hundredth.
    static let edges: [Double] = [100, 179.48, 322.14, 578.18, 1_037.73, 1_862.55, 3_342.95, 6_000]

    @Test(arguments: 0...7)
    func theEdgesAreEvenInLogFrequencyFromOneHundredHertzToSixKilohertz(_ index: Int) {
        #expect(abs(SpectrumBins.edgesHz[index] - Self.edges[index]) < 0.01, "\(SpectrumBins.edgesHz[index])")
    }

    @Test(arguments: 0..<7)
    func eachBandTakesTheBinsBetweenItsEdges(_ band: Int) {
        let bins = SpectrumBins.bands[band]
        #expect(bins.lowerBound == Int((SpectrumBins.edgesHz[band] / 15.625).rounded(.up)))
        #expect(bins.upperBound == Int((SpectrumBins.edgesHz[band + 1] / 15.625).rounded(.up)))
        #expect(bins.count >= 5, "band \(band) is \(bins)")
    }

    @Test func theBandsAreSevenContiguousRangesFromBinSevenToBin384() {
        let bands = SpectrumBins.bands
        #expect(bands.count == SpectrumBins.count)
        #expect(bands.map(\.lowerBound) + [bands.last?.upperBound ?? 0] == [7, 12, 21, 38, 67, 120, 214, 384])
        #expect(bands.first?.lowerBound == 7, "100 Hz is bin 6.4 at 15.625 Hz a bin")
        #expect(bands.last?.upperBound == 384, "6 kHz is bin 384")
        for index in bands.indices.dropFirst() {
            #expect(bands[index].lowerBound == bands[index - 1].upperBound, "gap before band \(index)")
        }
    }

    @Test(arguments: [
        (Float(-60), Float(0)), (-18, 1), (-39, 0.5), (-70, 0), (0, 1), (-.infinity, 0), (.nan, 0),
    ])
    func powerMapsLinearlyBetweenTheFloorAndTheCeiling(_ powerDB: Float, _ expected: Float) {
        for band in 0..<SpectrumBins.count {
            #expect(abs(SpectrumBins.level(powerDB: powerDB, band: band) - expected) < 1e-5, "band \(band)")
        }
    }

    @Test(arguments: [-1, 7, 100])
    func aBandOutsideTheTableReadsZero(_ band: Int) {
        #expect(SpectrumBins.level(powerDB: -20, band: band) == 0)
    }

    @Test func aRiseIsImmediate() {
        var bins = SpectrumBins()
        bins.push(levels: Array(repeating: 0.7, count: 7))
        #expect(bins.bars == Array(repeating: 0.7, count: 7))
    }

    @Test func aFallTakesTenthsAndReachesRestInTenReads() {
        var bins = SpectrumBins()
        bins.push(levels: Array(repeating: 1, count: 7))
        for read in 1...10 {
            bins.push(levels: Array(repeating: 0, count: 7))
            let expected = max(0, 1 - Float(read) / 10)
            for bar in bins.bars { #expect(abs(bar - expected) < 1e-5, "read \(read): \(bar)") }
        }
        #expect(bins.bars == Array(repeating: 0, count: 7))
    }

    @Test func aFallStopsAtTheTarget() {
        var bins = SpectrumBins()
        bins.push(levels: Array(repeating: 1, count: 7))
        bins.push(levels: Array(repeating: 0.95, count: 7))
        for bar in bins.bars { #expect(abs(bar - 0.95) < 1e-5) }
    }

    @Test func theBarsShowTheBandsLowestInTheMiddle() {
        var bins = SpectrumBins()
        bins.push(levels: [0.0, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6])
        #expect(SpectrumBins.barOrder == [5, 3, 1, 0, 2, 4, 6])
        #expect(bins.bars == [0.5, 0.3, 0.1, 0.0, 0.2, 0.4, 0.6])
    }

    @Test func missingAndNonFiniteLevelsReadZero() {
        var bins = SpectrumBins()
        bins.push(levels: [.nan, .infinity, 2, -1])
        #expect(bins.bars == [0, 0, 0, 0, 1, 0, 0])
    }

    @Test func silenceAndResetDrawNothing() {
        var bins = SpectrumBins()
        #expect(bins.bars == Array(repeating: 0, count: 7))
        bins.push(levels: Array(repeating: 0, count: 7))
        #expect(bins.bars == Array(repeating: 0, count: 7))
        bins.push(levels: Array(repeating: 0.8, count: 7))
        bins.reset()
        #expect(bins == SpectrumBins())
    }
}

@Suite struct SpectrumAnalyzerTests {
    static func sine(_ hertz: Double, amplitude: Float, count: Int = SpectrumBins.windowSize) -> [Float] {
        (0..<count).map { amplitude * Float(sin(2 * Double.pi * hertz * Double($0) / 16_000)) }
    }

    static func centre(_ band: Int) -> Double {
        (SpectrumBins.edgesHz[band] * SpectrumBins.edgesHz[band + 1]).squareRoot()
    }

    @Test func silenceAndAnEmptyWindowReadZero() throws {
        let analyzer = try #require(SpectrumAnalyzer())
        #expect(analyzer.levels(Array(repeating: 0, count: 1_024)) == Array(repeating: 0, count: 7))
        #expect(analyzer.levels([]) == Array(repeating: 0, count: 7))
    }

    @Test func aWindowWithANonFiniteSampleReadsAsSilence() throws {
        let analyzer = try #require(SpectrumAnalyzer())
        var window = Self.sine(1_000, amplitude: 0.5)
        window[100] = .nan
        #expect(analyzer.levels(window) == Array(repeating: 0, count: 7))
    }

    /// A sine of 0.1 at a band's geometric centre reads -20 dBFS in that band, within 0.5 dB, and that band loudest.
    @Test(arguments: 0..<7)
    func aSineReadsItsAmplitudeInItsBand(_ band: Int) throws {
        let analyzer = try #require(SpectrumAnalyzer())
        let levels = analyzer.levels(Self.sine(Self.centre(band), amplitude: 0.1))
        let expected = SpectrumBins.level(powerDB: -20, band: band)
        #expect(abs(levels[band] - expected) < 0.5 / 42, "band \(band): \(levels[band]) against \(expected)")
        #expect(levels.firstIndex(of: levels.max() ?? 0) == band, "\(levels)")
    }

    @Test func aShortWindowIsPaddedWithSilenceAtItsStart() throws {
        let analyzer = try #require(SpectrumAnalyzer())
        let levels = analyzer.levels(Self.sine(Self.centre(3), amplitude: 0.1, count: 512))
        #expect(levels.firstIndex(of: levels.max() ?? 0) == 3)
    }
}

@Suite struct PlayoutCursorTests {
    @Test(arguments: [
        (3_200, 1_600, Duration.zero, 1_600),
        (3_200, 1_600, .milliseconds(50), 2_400),
        (3_200, 1_600, .milliseconds(100), 3_200),
        (3_200, 1_600, .milliseconds(250), 3_200),
        (3_200, 1_600, .milliseconds(-10), 1_600),
        (3_200, 0, .milliseconds(40), 3_200),
        (1_000, 1_600, .milliseconds(10), 160),
        (0, 0, .zero, 0),
    ])
    func theWindowPlaysTheNewestBufferOut(_ newest: Int, _ lastBuffer: Int, _ elapsed: Duration, _ end: Int) {
        #expect(PlayoutCursor.end(newest: newest, lastBuffer: lastBuffer, elapsed: elapsed) == end)
    }
}
