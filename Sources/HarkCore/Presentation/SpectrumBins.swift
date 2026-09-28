import Foundation

/// The HUD's 7 bars: the voice's spectrum, one pitch band per bar, drawn like Apple Music's visualizer.
///
/// The user's redesign of 2026-09-27, in place of the 16 bottom-aligned bars of 2026-09-24: seven capsules that grow
/// up and down from a centre line, the lowest pitch in the middle and higher bands alternating outwards, which gives
/// a bell in speech. The bands are spaced evenly in log frequency from 100 Hz, under a low voice's fundamental, to
/// 6 kHz. A band's power maps linearly in dB between `floorDB` and `ceilingDB`, with no tilt. The window was tuned on
/// speech at an active-speech level of -26 dBFS with -60 dBFS noise: silence and pauses read 0 on every band, and
/// speech medians run from 0.15 to 0.81 over the 7 bands in English and French. If the live mic sits far from that,
/// floor and ceiling move together, keeping the same 42 dB span. `SpectrumAnalyzer` measures the bands; this holds
/// the levels between reads.
public struct SpectrumBins: Sendable, Equatable {
    public static let count = 7
    /// 64 ms at 16 kHz: 15.625 Hz per bin, so even the lowest band spans five bins.
    public static let windowSize = 1_024
    public static let lowestHz: Double = 100
    public static let highestHz: Double = 6_000
    public static let floorDB: Float = -60
    public static let ceilingDB: Float = -18
    /// The fall of a band per 33 ms read: a full bar comes to rest in 10 reads, so a syllable does not blink.
    public static let releasePerTick: Float = 0.10
    /// The band each bar shows, left to right: the lowest in the middle, higher ones alternating outwards.
    public static let barOrder = [5, 3, 1, 0, 2, 4, 6]

    static let binHz = 16_000 / Double(windowSize)

    /// The band edges in Hz, `lowestHz · (highestHz / lowestHz)^(b / count)`.
    public static let edgesHz: [Double] = (0...count).map { index in
        lowestHz * pow(highestHz / lowestHz, Double(index) / Double(count))
    }

    /// The FFT bins of each band: bin k, at k · `binHz`, belongs to the band whose edges hold it, lower edge included.
    public static let bands: [Range<Int>] = {
        let edges = edgesHz.map { Int(($0 / binHz).rounded(.up)) }
        return (0..<count).map { edges[$0]..<edges[$0 + 1] }
    }()

    /// The smoothed levels, `0...1`, in `barOrder`: left to right as drawn.
    public private(set) var bars: [Float]
    private var smoothed: [Float]

    public init() {
        smoothed = Array(repeating: 0, count: Self.count)
        bars = Array(repeating: 0, count: Self.count)
    }

    /// One read's levels by band index, `0...1`: instant rise, fall capped at `releasePerTick`. A missing band reads
    /// 0, a non-finite level reads 0.
    public mutating func push(levels: [Float]) {
        for band in 0..<Self.count {
            let raw = band < levels.count ? levels[band] : 0
            let level = raw.isFinite ? min(max(raw, 0), 1) : 0
            smoothed[band] = max(level, smoothed[band] - Self.releasePerTick, 0)
        }
        bars = Self.barOrder.map { smoothed[$0] }
    }

    public mutating func reset() {
        self = SpectrumBins()
    }

    /// A band's power in dBFS, where a full-scale sine inside the band reads 0, to `0...1`. The band is checked
    /// only so an index outside the table reads 0.
    public static func level(powerDB: Float, band: Int) -> Float {
        guard powerDB.isFinite, bands.indices.contains(band) else { return 0 }
        return min(max((powerDB - floorDB) / (ceilingDB - floorDB), 0), 1)
    }
}
