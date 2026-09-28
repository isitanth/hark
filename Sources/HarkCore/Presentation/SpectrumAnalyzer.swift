import Accelerate
import Foundation

/// The FFT behind `SpectrumBins`: a Hann-windowed 1024-point real transform, summed into the 7 bands.
///
/// It keeps its FFT setup and scratch buffers, so a read allocates nothing but its result. Not `Sendable`: one reader
/// owns it, the HUD on the main actor. Accelerate's `vDSP` is a system framework, not a dependency.
public final class SpectrumAnalyzer {
    private let fft: vDSP.FFT<DSPSplitComplex>
    private let hann: [Float]
    private var input: [Float]
    private var windowed: [Float]
    private var real: [Float]
    private var imaginary: [Float]
    private var power: [Float]

    /// A full-scale sine inside a band sums to 3·N²/8 over its bins in vDSP's real FFT, which returns twice the
    /// DFT: this brings it to 1, so a band reads 20·log10 of the amplitude. Checked against sines in the tests.
    private static let powerScale = 8 / (3 * Float(SpectrumBins.windowSize * SpectrumBins.windowSize))

    /// Nil only if vDSP cannot make the setup.
    public init?() {
        let size = SpectrumBins.windowSize
        guard
            let fft = vDSP.FFT(
                log2n: vDSP_Length(size.trailingZeroBitCount), radix: .radix2, ofType: DSPSplitComplex.self)
        else { return nil }
        self.fft = fft
        hann = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: size, isHalfWindow: false)
        input = Array(repeating: 0, count: size)
        windowed = Array(repeating: 0, count: size)
        real = Array(repeating: 0, count: size / 2)
        imaginary = Array(repeating: 0, count: size / 2)
        power = Array(repeating: 0, count: size / 2)
    }

    /// The 7 band levels by band index, `0...1`, of the last `SpectrumBins.windowSize` samples; a shorter window is
    /// padded with silence at its start. A window holding a non-finite sample reads as silence.
    public func levels(_ window: [Float]) -> [Float] {
        let size = SpectrumBins.windowSize
        let tail = window.suffix(size)
        vDSP.fill(&input, with: 0)
        input.replaceSubrange((size - tail.count)..<size, with: tail)
        vDSP.multiply(input, hann, result: &windowed)

        let half = size / 2
        real.withUnsafeMutableBufferPointer { real in
            imaginary.withUnsafeMutableBufferPointer { imaginary in
                guard let realBase = real.baseAddress, let imaginaryBase = imaginary.baseAddress else { return }
                var split = DSPSplitComplex(realp: realBase, imagp: imaginaryBase)
                windowed.withUnsafeBufferPointer { samples in
                    samples.withMemoryRebound(to: DSPComplex.self) { pairs in
                        guard let pairs = pairs.baseAddress else { return }
                        vDSP_ctoz(pairs, 2, &split, 1, vDSP_Length(half))
                    }
                }
                fft.forward(input: split, output: &split)
                vDSP.squareMagnitudes(split, result: &power)
            }
        }

        return SpectrumBins.bands.enumerated().map { band, bins in
            let sum = power[bins].reduce(0, +)
            return SpectrumBins.level(powerDB: 10 * log10(sum * Self.powerScale), band: band)
        }
    }
}
