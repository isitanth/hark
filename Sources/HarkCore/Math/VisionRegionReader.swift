import CoreGraphics
import CoreText
import Foundation
import Vision
import os

// The reader (M13.3): Vision reads the framed region on macOS 26, nothing below it. The only file that imports
// Vision. The raster stays in memory: Vision gets CGImages, never a URL.

/// The reader this Mac can run.
public enum RegionReaders {
    /// macOS 26 or later.
    public static var available: Bool {
        if #available(macOS 26, *) { return true }
        return false
    }

    /// `macDecimal` is the Mac's decimal separator, the number parser's last resort: the app reads it, HarkCore reads
    /// no locale of its own.
    public static func make(macDecimal: Character = ".") -> any RegionReading {
        if #available(macOS 26, *) { return VisionRegionReader(macDecimal: macDecimal) }
        return NullRegionReader()
    }
}

/// Reads one frame at a time: the document request, then the sheet builder with crops read 8 at a time.
@available(macOS 26, *)
public actor VisionRegionReader: RegionReading {
    private static let logger = Logger(subsystem: HarkLog.subsystem, category: "reader")
    /// A read or a warm-up this recent leaves the models loaded.
    static let warmFor = Duration.seconds(600)

    private let recognizer: any TextRecognizing
    private let options: ReaderOptions
    private let amounts: SheetBuilder.AmountSplitter
    private let elapsed: @Sendable () -> Duration
    /// The opt-in bench's hook: every crop read, by box and rung.
    private let onCrop: (@Sendable (CGRect, Rung, String) -> Void)?
    private var lastWarm: Duration?
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(macDecimal: Character = ".") {
        var options = ReaderOptions.frozen
        options.macDecimal = macDecimal
        self.init(recognizer: VisionTextRecognizer(), options: options)
    }

    init(
        recognizer: any TextRecognizing, options: ReaderOptions = .frozen,
        amounts: @escaping SheetBuilder.AmountSplitter = { DisplayedNumber.amounts(in: $0) },
        clock: any Clock<Duration> = ContinuousClock(), onCrop: (@Sendable (CGRect, Rung, String) -> Void)? = nil
    ) {
        self.recognizer = recognizer
        self.options = options
        self.amounts = amounts
        self.elapsed = Self.stopwatch(clock)
        self.onCrop = onCrop
    }

    private static func stopwatch<C: Clock<Duration>>(_ clock: C) -> @Sendable () -> Duration {
        let start = clock.now
        return { start.duration(to: clock.now) }
    }

    /// A cancelled read reads nothing: the controller drops its result, and it neither logs nor counts as warm.
    public func read(_ raster: RegionRaster) async -> Result<CellSheet, ReaderFailure> {
        await acquire()
        defer { release() }
        let start = elapsed()
        guard !Task.isCancelled else { return .success(Self.emptySheet) }
        guard let image = Self.capped(raster.image, cap: options.inputCap) else {
            Self.logger.error("reader: the frame could not be scaled to the reader's cap")
            return .failure(.vision)
        }
        let document: RawDocument
        do {
            document = try await recognizer.document(image)
        } catch {
            Self.logger.error("reader: the document request failed")
            return .failure(.vision)
        }
        guard !Task.isCancelled else { return .success(Self.emptySheet) }
        let recognizer = recognizer
        let onCrop = onCrop
        // The re-reads are cut from the native raster: its boxes are normalized, so a capped frame's map unchanged.
        let native = raster.image
        let built = await SheetBuilder.build(document, options: options, amounts: amounts) { boxes, rung in
            await Self.cropReads(native, boxes: boxes, rung: rung, recognizer: recognizer, onCrop: onCrop)
        }
        guard !Task.isCancelled else { return .success(Self.emptySheet) }
        let ms = Int((elapsed() - start) / .milliseconds(1))
        lastWarm = elapsed()
        let tables = Set(built.sheet.cells.compactMap(\.table)).count
        Self.logger.notice(
            "reader: \(built.sheet.cells.count, privacy: .public) cells, \(tables, privacy: .public) tables, \(ms, privacy: .public) ms"
        )
        return .success(CellSheet(cells: built.sheet.cells, convention: built.sheet.convention, readMs: ms))
    }

    /// Under the read's lock, so a read that comes during a cold warm-up waits for it instead of loading the models a
    /// second time. Only a warm-up that succeeded counts.
    public func prewarm() async {
        if busy { return }
        if let lastWarm, elapsed() - lastWarm < Self.warmFor { return }
        guard let image = Self.warmUpImage() else { return }
        await acquire()
        defer { release() }
        do {
            _ = try await recognizer.document(image)
            _ = try await recognizer.lines(image, level: .accurate)
            _ = try await recognizer.lines(image, level: .fast)
            lastWarm = elapsed()
        } catch {
            Self.logger.error("reader: the warm-up failed")
        }
    }

    private static let emptySheet = CellSheet(cells: [], convention: .plain, readMs: 0)

    /// One read at a time: actor reentrancy would let a second one in at the first await.
    private func acquire() async {
        guard busy else {
            busy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

// Pixels: the input cap, the crops, the warm-up image. In memory only.
@available(macOS 26, *)
extension VisionRegionReader {
    /// The raster with its longest side capped, drawn into sRGB; the image itself when it fits.
    static func capped(_ image: CGImage, cap: Int) -> CGImage? {
        let longest = max(image.width, image.height)
        guard longest > cap else { return image }
        let ratio = Double(cap) / Double(longest)
        let width = Int((Double(image.width) * ratio).rounded())
        let height = Int((Double(image.height) * ratio).rounded())
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// A box padded by `pad` source pixels, cut from the image and upscaled (reader.swift's crop).
    static func crop(_ image: CGImage, _ box: CGRect, scale: Int, pad: Int) -> CGImage? {
        let w = Double(image.width)
        let h = Double(image.height)
        let p = Double(pad)
        let x0 = max(0, Double(box.origin.x) * w - p)
        let y0 = max(0, Double(box.origin.y) * h - p)
        let x1 = min(w, Double(box.origin.x + box.size.width) * w + p)
        let y1 = min(h, Double(box.origin.y + box.size.height) * h + p)
        guard x1 - x0 >= 2, y1 - y0 >= 2,
            let cut = image.cropping(to: CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0))
        else { return nil }
        if scale == 1 { return cut }
        let width = Int((Double(cut.width) * Double(scale)).rounded())
        let height = Int((Double(cut.height) * Double(scale)).rounded())
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(cut, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// A crop's text: its observations left to right, only those whose centre lies in the middle 60 % of its height
    /// when there are any (a neighbouring row bleeds in at the edges).
    static func text(of lines: [RawLine]) -> String {
        let sorted = SheetBuilder.stableSorted(lines) { $0.box.origin.x < $1.box.origin.x }
        let middle = sorted.filter {
            let centre = $0.box.origin.y + $0.box.size.height / 2
            return 0.2 <= centre && centre <= 0.8
        }
        return (middle.isEmpty ? sorted : middle).map(\.text).joined(separator: " ")
    }

    /// One rung's crops, 8 in flight. A crop that cannot be cut or read reads blank: the cell keeps its document text.
    static func cropReads(
        _ image: CGImage, boxes: [CGRect], rung: Rung, recognizer: any TextRecognizing,
        onCrop: (@Sendable (CGRect, Rung, String) -> Void)?
    ) async -> [String] {
        var reads = [String](repeating: "", count: boxes.count)
        await withTaskGroup(of: (Int, String).self) { group in
            var next = 0
            func add() {
                let index = next
                next += 1
                let piece = crop(image, boxes[index], scale: rung.scale, pad: rung.pad)
                group.addTask {
                    guard let piece, !Task.isCancelled else { return (index, "") }
                    do {
                        return (index, text(of: try await recognizer.lines(piece, level: rung.level)))
                    } catch {
                        logger.error("reader: a crop read failed")
                        return (index, "")
                    }
                }
            }
            while next < min(ReaderVocabulary.cropsInFlight, boxes.count) { add() }
            while let (index, read) = await group.next() {
                reads[index] = read
                if next < boxes.count { add() }
            }
        }
        if let onCrop {
            for (box, read) in zip(boxes, reads) { onCrop(box, rung, read) }
        }
        return reads
    }

    /// "1 234,56 €" drawn with CoreText into a 240×64 sRGB bitmap: a blank image returns early and may skip
    /// recognition (b3 §6).
    static func warmUpImage() -> CGImage? {
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil, width: 240, height: 64, bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 240, height: 64))
        let font = CTFontCreateWithName("Helvetica" as CFString, 28, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(
                srgbRed: 0, green: 0, blue: 0, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "1 234,56 €", attributes: attributes))
        context.textPosition = CGPoint(x: 16, y: 22)
        CTLineDraw(line, context)
        return context.makeImage()
    }
}

/// Vision's requests exactly as V2F ran them: the document request with its defaults, and the text request in English
/// and French with no language detection and no correction. Boxes flipped to a top-left origin, full precision.
@available(macOS 26, *)
struct VisionTextRecognizer: TextRecognizing {
    func document(_ image: CGImage) async throws -> RawDocument {
        let observations = try await RecognizeDocumentsRequest().perform(on: image)
        var result = RawDocument()
        for observation in observations {
            let document = observation.document
            for table in document.tables {
                var cells: [RawCell] = []
                for row in table.rows {
                    for cell in row {
                        cells.append(
                            RawCell(
                                row: cell.rowRange.lowerBound, column: cell.columnRange.lowerBound,
                                rowSpan: cell.rowRange.count, columnSpan: cell.columnRange.count,
                                transcript: cell.content.text.transcript,
                                box: Self.flip(cell.content.boundingRegion.boundingBox.cgRect),
                                lines: cell.content.text.lines.map {
                                    RawLine(
                                        text: $0.topCandidates(1).first?.string ?? $0.transcript,
                                        box: Self.flip($0.boundingBox.cgRect))
                                }))
                    }
                }
                result.tables.append(RawTable(box: Self.flip(table.boundingRegion.boundingBox.cgRect), cells: cells))
            }
            for line in document.text.lines {
                result.lines.append(
                    RawLine(text: line.transcript, box: Self.flip(line.boundingRegion.boundingBox.cgRect)))
            }
        }
        return result
    }

    func lines(_ image: CGImage, level: RecognitionLevel) async throws -> [RawLine] {
        var request = RecognizeTextRequest()
        request.recognitionLevel = level == .fast ? .fast : .accurate
        request.usesLanguageCorrection = false
        request.automaticallyDetectsLanguage = false
        request.recognitionLanguages = [Locale.Language(identifier: "en-US"), Locale.Language(identifier: "fr-FR")]
        return try await request.perform(on: image).map {
            RawLine(text: $0.topCandidates(1).first?.string ?? $0.transcript, box: Self.flip($0.boundingBox.cgRect))
        }
    }

    /// Vision's bottom-left origin to the top-left one.
    static func flip(_ box: CGRect) -> CGRect {
        CGRect(x: box.origin.x, y: 1 - box.origin.y - box.size.height, width: box.size.width, height: box.size.height)
    }
}
