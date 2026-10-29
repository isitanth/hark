import CoreGraphics
import Foundation
import HarkCore
import Testing
import os

/// One recorded case of Tests/HarkCoreTests/Fixtures/Math/reader (see its README).
struct ReaderFixture: Decodable {
    struct Crop: Decodable {
        let box: [CGFloat]
        let rung: Int
        let text: String
    }

    struct ExpectedCell: Decodable, Equatable, CustomStringConvertible {
        let id: String
        let text: String
        let table: Int?
        let row: Int?
        let column: Int?
        let uncertain: Bool

        var description: String { "\(id) t\(table.map(String.init) ?? "-") r\(row ?? -1) c\(column ?? -1)" }
    }

    struct Expected: Decodable {
        let cells: [ExpectedCell]
        let listing: String
        let splitListing: String
    }

    let `case`: String
    let document: RawDocument
    let crops: [Crop]
    /// harness.amount_spans for every text holding two amounts or more, in Unicode scalar offsets.
    let spans: [String: [[Int]]]
    let expected: Expected

    static let cases = [
        "c01-invoices-en-net", "c02-invoices-fr-unpaid", "c03-bank-fr-restaurants", "c04-bank-us-deposits",
        "c05-bank-uk-balance", "c06-saas-dark-seats", "c07-card-fr-parentheses", "c08-receipt-fr-tva20",
        "c09-restaurant-en-split", "c10-timesheet-en-project", "c11-utility-fr-percent", "c12-grocery-en-unitprice",
        "c13-expenses-en-travel", "c14-sheet-en-avg", "c15-sheet-fr-dark-max", "c16-sheet-en-growth",
        "c17-dashboard-dark-count", "c18-grades-fr-weighted", "c19-dense-en-filter", "c20-budget-fr-variance",
    ]

    static func load(_ name: String) throws -> ReaderFixture {
        let directory = try #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
        let url = directory.appending(path: "Math").appending(path: "reader").appending(path: "\(name).json")
        return try JSONDecoder().decode(ReaderFixture.self, from: Data(contentsOf: url))
    }

    /// A fake of harness.amount_spans on this case's own rows: what S1's splitter will give.
    var splitter: SheetBuilder.AmountSplitter {
        let spans = spans
        return { text in
            guard let pairs = spans[text] else { return [] }
            let scalars = text.unicodeScalars
            return pairs.map { pair in
                let start = scalars.index(scalars.startIndex, offsetBy: pair[0])
                let end = scalars.index(scalars.startIndex, offsetBy: pair[1])
                return start..<end
            }
        }
    }

    /// The recorded crops as a closure for `SheetBuilder.build`, which records every request.
    func scriptedCrops() -> ScriptedCrops { ScriptedCrops(crops) }
}

/// Answers crop requests by (box, rung) from a recording; any box it was not given is recorded as unknown.
final class ScriptedCrops: Sendable {
    private struct State {
        var calls: [(boxes: [CGRect], rung: Rung)] = []
        var unknown: [String] = []
    }

    private let table: [(box: CGRect, rung: Int, text: String)]
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(_ crops: [ReaderFixture.Crop]) {
        table = crops.map {
            (CGRect(x: $0.box[0], y: $0.box[1], width: $0.box[2], height: $0.box[3]), $0.rung, $0.text)
        }
    }

    init(_ answers: [(box: CGRect, rung: Int, text: String)]) {
        table = answers
    }

    var callCount: Int { state.withLock { $0.calls.count } }
    var rungs: [Rung] { state.withLock { $0.calls.map(\.rung) } }
    var unknown: [String] { state.withLock { $0.unknown } }

    func read(_ boxes: [CGRect], _ rung: Rung) -> [String] {
        let index = Rung.ladder.firstIndex(of: rung) ?? -1
        var missing: [String] = []
        let texts = boxes.map { box -> String in
            if let hit = table.first(where: { $0.rung == index && Self.same($0.box, box) }) { return hit.text }
            missing.append("\(rung) \(box)")
            return ""
        }
        let unknown = missing
        state.withLock {
            $0.calls.append((boxes, rung))
            $0.unknown += unknown
        }
        return texts
    }

    private static func same(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.origin.x - b.origin.x) < 1e-9 && abs(a.origin.y - b.origin.y) < 1e-9
            && abs(a.size.width - b.size.width) < 1e-9 && abs(a.size.height - b.size.height) < 1e-9
    }
}

/// A `TextRecognizing` that answers from a script and records what it was asked: no Vision.
final class ScriptedRecognizer: TextRecognizing {
    struct Call: Equatable {
        var kind: String
        var width: Int
        var height: Int
    }

    private struct State {
        var calls: [Call] = []
        var events: [String] = []
    }

    private let script: RawDocument
    private let failDocument: Bool
    private let failLines: Bool
    private let cancelAfterDocument: Bool
    private let documentPause: Duration
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(
        _ script: RawDocument = RawDocument(), failDocument: Bool = false, failLines: Bool = false,
        cancelAfterDocument: Bool = false, documentPause: Duration = .zero
    ) {
        self.script = script
        self.failDocument = failDocument
        self.failLines = failLines
        self.cancelAfterDocument = cancelAfterDocument
        self.documentPause = documentPause
    }

    struct Failure: Error {}

    var calls: [Call] { state.withLock { $0.calls } }
    var events: [String] { state.withLock { $0.events } }

    func document(_ image: CGImage) async throws -> RawDocument {
        state.withLock {
            $0.calls.append(Call(kind: "document", width: image.width, height: image.height))
            $0.events.append("start")
        }
        if documentPause > .zero { try? await Task.sleep(for: documentPause) }
        state.withLock { $0.events.append("end") }
        if failDocument { throw Failure() }
        if cancelAfterDocument { withUnsafeCurrentTask { $0?.cancel() } }
        return script
    }

    func lines(_ image: CGImage, level: RecognitionLevel) async throws -> [RawLine] {
        state.withLock { $0.calls.append(Call(kind: level.rawValue, width: image.width, height: image.height)) }
        if failLines { throw Failure() }
        return []
    }
}

/// A blank RGBA image of that size, in memory.
func blankImage(width: Int, height: Int) throws -> CGImage {
    let context = try #require(
        CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    return try #require(context.makeImage())
}
