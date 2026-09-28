import Foundation

/// RIFF/WAVE writer for the debug audio dump: IEEE float, mono, with the `fact` chunk that non-PCM formats require.
public enum WAVEncoder {
    private static let headerSize = 58
    private static let bytesPerSample = MemoryLayout<Float>.size

    public static func float32Mono(_ samples: [Float], sampleRate: Int) -> Data {
        let dataSize = samples.count * bytesPerSample
        var data = Data(capacity: headerSize + dataSize)

        data.append(contentsOf: "RIFF".utf8)
        append(UInt32(clamping: headerSize - 8 + dataSize), to: &data)
        data.append(contentsOf: "WAVE".utf8)

        data.append(contentsOf: "fmt ".utf8)
        append(UInt32(18), to: &data)
        append(UInt16(3), to: &data)  // WAVE_FORMAT_IEEE_FLOAT
        append(UInt16(1), to: &data)
        append(UInt32(clamping: sampleRate), to: &data)
        append(UInt32(clamping: sampleRate * bytesPerSample), to: &data)
        append(UInt16(bytesPerSample), to: &data)
        append(UInt16(bytesPerSample * 8), to: &data)
        append(UInt16(0), to: &data)

        data.append(contentsOf: "fact".utf8)
        append(UInt32(4), to: &data)
        append(UInt32(clamping: samples.count), to: &data)

        data.append(contentsOf: "data".utf8)
        append(UInt32(clamping: dataSize), to: &data)
        // Apple Silicon only, so host order is already little-endian.
        samples.withUnsafeBufferPointer { data.append($0) }
        return data
    }

    private static func append(_ value: some FixedWidthInteger, to data: inout Data) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
}
