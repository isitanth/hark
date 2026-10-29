import CoreGraphics
import Foundation

// What Vision gave, in Hark's own types (M13.3): the sheet builder reads these, so no step after Vision imports it.
// Boxes are normalized to the image, top-left origin. Never logged, never on disk outside the opt-in bench.

/// One line of text and its box.
public struct RawLine: Sendable, Equatable, Codable {
    public var text: String
    public var box: CGRect

    public init(text: String, box: CGRect) {
        self.text = text
        self.box = box
    }

    enum CodingKeys: String, CodingKey { case text, box }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decode(String.self, forKey: .text)
        box = try BoxCoding.decode(container, .box)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(text, forKey: .text)
        try container.encode(BoxCoding.array(box), forKey: .box)
    }
}

/// One table cell as the document request gave it: its place, its spans, its lines joined by `\n`.
public struct RawCell: Sendable, Equatable, Codable {
    public var row: Int
    public var column: Int
    public var rowSpan: Int
    public var columnSpan: Int
    public var transcript: String
    public var box: CGRect
    public var lines: [RawLine]

    public init(
        row: Int, column: Int, rowSpan: Int = 1, columnSpan: Int = 1, transcript: String, box: CGRect,
        lines: [RawLine]
    ) {
        self.row = row
        self.column = column
        self.rowSpan = rowSpan
        self.columnSpan = columnSpan
        self.transcript = transcript
        self.box = box
        self.lines = lines
    }

    enum CodingKeys: String, CodingKey {
        case row = "r"
        case column = "c"
        case rowSpan = "rs"
        case columnSpan = "cs"
        case transcript, box, lines
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        row = try container.decode(Int.self, forKey: .row)
        column = try container.decode(Int.self, forKey: .column)
        rowSpan = try container.decodeIfPresent(Int.self, forKey: .rowSpan) ?? 1
        columnSpan = try container.decodeIfPresent(Int.self, forKey: .columnSpan) ?? 1
        transcript = try container.decode(String.self, forKey: .transcript)
        box = try BoxCoding.decode(container, .box)
        lines = try container.decode([RawLine].self, forKey: .lines)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(row, forKey: .row)
        try container.encode(column, forKey: .column)
        try container.encode(rowSpan, forKey: .rowSpan)
        try container.encode(columnSpan, forKey: .columnSpan)
        try container.encode(transcript, forKey: .transcript)
        try container.encode(BoxCoding.array(box), forKey: .box)
        try container.encode(lines, forKey: .lines)
    }
}

public struct RawTable: Sendable, Equatable, Codable {
    public var box: CGRect
    public var cells: [RawCell]

    public init(box: CGRect, cells: [RawCell]) {
        self.box = box
        self.cells = cells
    }

    enum CodingKeys: String, CodingKey { case box, cells }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        box = try BoxCoding.decode(container, .box)
        cells = try container.decode([RawCell].self, forKey: .cells)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(BoxCoding.array(box), forKey: .box)
        try container.encode(cells, forKey: .cells)
    }
}

/// The document request's output: its tables and every line of the image (inside the tables too).
public struct RawDocument: Sendable, Equatable, Codable {
    public var tables: [RawTable]
    public var lines: [RawLine]

    public init(tables: [RawTable] = [], lines: [RawLine] = []) {
        self.tables = tables
        self.lines = lines
    }
}

/// A box as `[x, y, width, height]`, the prototype's JSON shape.
enum BoxCoding {
    static func array(_ box: CGRect) -> [CGFloat] {
        [box.origin.x, box.origin.y, box.size.width, box.size.height]
    }

    static func decode<K: CodingKey>(_ container: KeyedDecodingContainer<K>, _ key: K) throws -> CGRect {
        let values = try container.decode([CGFloat].self, forKey: key)
        guard values.count == 4 else {
            throw DecodingError.dataCorruptedError(forKey: key, in: container, debugDescription: "a box has 4 values")
        }
        return CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
    }
}

public enum RecognitionLevel: String, Sendable, Codable, CaseIterable {
    case accurate
    case fast
}

/// One re-read of the ladder: a recognizer, an upscale and a padding in source pixels.
public struct Rung: Sendable, Hashable, CustomStringConvertible {
    public let level: RecognitionLevel
    public let scale: Int
    public let pad: Int

    public init(level: RecognitionLevel, scale: Int, pad: Int = 6) {
        self.level = level
        self.scale = scale
        self.pad = pad
    }

    /// V2F's ladder: accurate 2x, 3x, 1x, then the fast recognizer at 2x, which reads the lone digits the accurate
    /// one drops.
    public static let ladder: [Rung] = [
        Rung(level: .accurate, scale: 2), Rung(level: .accurate, scale: 3), Rung(level: .accurate, scale: 1),
        Rung(level: .fast, scale: 2),
    ]

    /// `accurate 2x`, the prototype's name.
    public var description: String { "\(level.rawValue) \(scale)x" }
}

/// The seam between Vision and the rest: `VisionRegionReader` implements it with Vision, the tests with a script.
public protocol TextRecognizing: Sendable {
    func document(_ image: CGImage) async throws -> RawDocument
    /// Every observation of the image, boxes normalized to it.
    func lines(_ image: CGImage, level: RecognitionLevel) async throws -> [RawLine]
}
