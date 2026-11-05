import Accelerate
import CoreGraphics
import Foundation

// Finding the framed zone again after the page moved (M14, c3b §4.2, §5): Accelerate's cross-correlation, then a pixel
// check in each tinted cell, against the window-alone reference captured at the frame. Pure; it writes nothing, and no
// value it computes reaches a result: it outputs a pixel offset or nothing. A port of the M14.0 B3 probe's registration
// (docs/acceptance/M14-data/refind-spike/refind.swift), its thresholds the measured ones.

/// Where the zone is in a fresh capture of its window.
public enum ZoneMatch: Sendable, Equatable {
    /// Found with certainty: the zone moved by this many pixels from where the reference holds it.
    case found(CGVector)
    /// Two places pass the cell check (identical rows): never choose, the tints stay hidden.
    case ambiguous
    case notFound
}

public enum ZoneRegistration {
    /// `reference` is the window alone at the frame, in grey; `recapture` the same window now; `zone` and `cells` (the
    /// tinted boxes) in the reference's pixels. Both images live in memory only and are freed by the caller; the grey
    /// planes read from them here are freed on return. The offset is in the recapture's pixels, from the zone's place
    /// in the reference.
    public static func find(reference: CGImage, recapture: CGImage, zone: CGRect, cells: [CGRect]) -> ZoneMatch {
        let passing = candidates(reference: reference, recapture: recapture, zone: zone, cells: cells).filter(\.passes)
        switch passing.count {
        case 0: return .notFound
        case 1: return .found(passing[0].shift)
        default: return .ambiguous
        }
    }

    /// One place the registration looked at closely, with what the certainty rule read there.
    struct Candidate: Equatable {
        /// From the zone's place in the reference, in pixels.
        let shift: CGVector
        let ncc: Float
        let visible: Float
        let visibleCells: Int
        let meanMAD: Float
        let worstMAD: Float

        var passes: Bool {
            visibleCells >= 1 && visible >= minVisible && ncc >= nccFloor && meanMAD <= meanMADCeiling
                && worstMAD <= worstMADCeiling
        }
    }

    /// The coarse peaks, each refined at 1/2 then at full resolution and checked cell by cell; one entry per place.
    static func candidates(reference: CGImage, recapture: CGImage, zone: CGRect, cells: [CGRect]) -> [Candidate] {
        guard let template = Template(reference: reference, zone: zone, cells: cells),
            let band = GreyPlane(recapture)
        else { return [] }
        let factor = template.coarseFactor
        let bandPyramid = Pyramid(band, coarseFactor: factor)
        let radius = max(1, Int((template.rowHeight / 2 / Double(factor)).rounded()))
        let peaks = coarsePeaks(
            template.pyramid.coarse, bandPyramid.coarse, minVisible: minVisible, radius: radius, count: 5)
        let halfSAT = SAT(bandPyramid.half)
        let fullSAT = SAT(bandPyramid.full)
        var seen = Set<Offset>()
        var result: [Candidate] = []
        for peak in peaks {
            guard
                let half = refine(
                    template.pyramid.half, template.halfSAT, bandPyramid.half, halfSAT,
                    around: Offset(x: peak.offset.x * factor / 2, y: peak.offset.y * factor / 2), radius: factor / 2 + 1
                ),
                let full = refine(
                    template.pyramid.full, template.fullSAT, bandPyramid.full, fullSAT,
                    around: Offset(x: half.offset.x * 2, y: half.offset.y * 2), radius: 1)
            else { continue }
            guard seen.insert(full.offset).inserted else { continue }
            let check = cellCheck(template, bandPyramid.full, at: full.offset)
            result.append(
                Candidate(
                    shift: CGVector(dx: full.offset.x - template.origin.x, dy: full.offset.y - template.origin.y),
                    ncc: full.ncc, visible: full.visible, visibleCells: check.visible, meanMAD: check.mean,
                    worstMAD: check.worst))
        }
        return result
    }

    /// The measured thresholds (c3b §5, M14.0 B3): NCC over the visible part, the cells' mean and worst MAD, the part
    /// of the zone in view.
    static let nccFloor: Float = 0.95
    static let meanMADCeiling: Float = 4
    static let worstMADCeiling: Float = 8
    static let minVisible: Float = 0.5
}

/// One input event over the anchored window, as the stillness detector reads it (c3b §3): never its content.
public struct InputRecord: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// A scroll event; `momentumEnded` on the last event of a trackpad's momentum.
        case scroll(momentumEnded: Bool)
        case key
        case buttonDown
        case buttonUp
    }

    public let kind: Kind
    /// On the detector's clock, from any origin.
    public let at: Duration

    public init(kind: Kind, at: Duration) {
        self.kind = kind
        self.at = at
    }
}

/// Hide on the first event that may move the page, recapture once it is still: 250 ms with no event, momentum ended,
/// no button down (c3b §2.3, the quiet delay M14.0 B3 sets). A pure reducer over timed records, with a test clock.
/// `momentumEnded` is true on any scroll that leaves no momentum running (a wheel's notch, a trackpad's last momentum
/// event); a scroll with momentum still to come keeps the detector waiting for one that ends it.
public struct StillnessDetector: Sendable, Equatable {
    public static let quiet: Duration = .milliseconds(250)

    public enum Action: Sendable, Equatable {
        case none
        case hide
        /// Still long enough: capture the window once and look for the zone.
        case recapture
    }

    /// Hidden and waiting for stillness.
    private var waiting = false
    private var lastEvent: Duration?
    private var buttonDown = false
    private var momentum = false

    public init() {}

    public mutating func record(_ event: InputRecord) -> Action {
        lastEvent = event.at
        switch event.kind {
        case .buttonUp:
            buttonDown = false
            return .none
        case .buttonDown:
            buttonDown = true
        case .key:
            break
        case .scroll(let momentumEnded):
            momentum = !momentumEnded
        }
        guard !waiting else { return .none }
        waiting = true
        return .hide
    }

    /// Called on the clock: `.recapture` once, when the page has been still for `quiet`.
    public mutating func tick(at: Duration) -> Action {
        guard waiting, !buttonDown, !momentum, let lastEvent, at - lastEvent >= Self.quiet else { return .none }
        waiting = false
        return .recapture
    }
}

// MARK: - The registration's grey planes, in memory only

extension ZoneRegistration {
    /// A pixel offset: the template's top-left in the band.
    fileprivate struct Offset: Hashable {
        let x: Int
        let y: Int
    }

    /// An 8-bit grey plane, row-major, top row first. Never written, never logged.
    fileprivate struct GreyPlane {
        let width: Int
        let height: Int
        var bytes: [UInt8]

        init(width: Int, height: Int, bytes: [UInt8]) {
            self.width = width
            self.height = height
            self.bytes = bytes
        }

        /// The image drawn into a DeviceGray context.
        init?(_ image: CGImage) {
            let width = image.width
            let height = image.height
            guard width > 0, height > 0 else { return nil }
            var bytes = [UInt8](repeating: 0, count: width * height)
            let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
                guard
                    let context = CGContext(
                        data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                        bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                        bitmapInfo: CGImageAlphaInfo.none.rawValue)
                else { return false }
                context.interpolationQuality = .none
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }
            guard drawn else { return nil }
            self.init(width: width, height: height, bytes: bytes)
        }

        func crop(x: Int, y: Int, width w: Int, height h: Int) -> GreyPlane {
            var out = [UInt8](repeating: 0, count: w * h)
            for row in 0..<h {
                for col in 0..<w { out[row * w + col] = bytes[(y + row) * width + x + col] }
            }
            return GreyPlane(width: w, height: h, bytes: out)
        }

        var floats: Grey {
            var out = [Float](repeating: 0, count: bytes.count)
            vDSP.convertElements(of: bytes, to: &out)
            return Grey(width: width, height: height, pixels: out)
        }

        /// Downscaled by `factor` with `vImageScale_Planar8`, the source cropped to a multiple of the factor so the
        /// template and the band scale by exactly the same ratio.
        func downscaled(by factor: Int) -> Grey {
            let w = max(1, width / factor)
            let h = max(1, height / factor)
            let croppedWidth = min(width, w * factor)
            let croppedHeight = min(height, h * factor)
            var source = bytes
            var target = [UInt8](repeating: 0, count: w * h)
            source.withUnsafeMutableBytes { s in
                target.withUnsafeMutableBytes { d in
                    var from = vImage_Buffer(
                        data: s.baseAddress, height: vImagePixelCount(croppedHeight),
                        width: vImagePixelCount(croppedWidth), rowBytes: width)
                    var to = vImage_Buffer(
                        data: d.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w)
                    _ = vImageScale_Planar8(&from, &to, nil, vImage_Flags(kvImageHighQualityResampling))
                }
            }
            return GreyPlane(width: w, height: h, bytes: target).floats
        }
    }

    /// A grey plane as Float values 0...255.
    fileprivate struct Grey {
        let width: Int
        let height: Int
        let pixels: [Float]
    }

    /// One plane at three scales: full, 1/2, 1/coarse.
    fileprivate struct Pyramid {
        let full: Grey
        let half: Grey
        let coarse: Grey

        init(_ plane: GreyPlane, coarseFactor: Int) {
            full = plane.floats
            half = plane.downscaled(by: 2)
            coarse = plane.downscaled(by: coarseFactor)
        }
    }

    /// Summed-area table, (w+1)×(h+1), for sums and sums of squares over any rectangle.
    fileprivate struct SAT {
        let stride: Int
        var sum: [Double]
        var squares: [Double]

        init(_ grey: Grey) {
            stride = grey.width + 1
            sum = [Double](repeating: 0, count: (grey.width + 1) * (grey.height + 1))
            squares = sum
            for y in 0..<grey.height {
                var rowSum = 0.0
                var rowSquares = 0.0
                for x in 0..<grey.width {
                    let value = Double(grey.pixels[y * grey.width + x])
                    rowSum += value
                    rowSquares += value * value
                    let i = (y + 1) * stride + x + 1
                    sum[i] = sum[i - stride] + rowSum
                    squares[i] = squares[i - stride] + rowSquares
                }
            }
        }

        /// Sums over [x0,x1)×[y0,y1).
        func sums(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) -> (sum: Double, squares: Double) {
            let a = y0 * stride + x0
            let b = y0 * stride + x1
            let c = y1 * stride + x0
            let d = y1 * stride + x1
            return (sum[d] - sum[b] - sum[c] + sum[a], squares[d] - squares[b] - squares[c] + squares[a])
        }
    }

    /// A tinted box in template pixels.
    fileprivate struct Box {
        let x: Int
        let y: Int
        let width: Int
        let height: Int
    }

    /// The zone at the frame: its grey template at three scales and the tinted boxes, in template pixels.
    fileprivate struct Template {
        /// The zone's top-left in the reference.
        let origin: Offset
        let pyramid: Pyramid
        let halfSAT: SAT
        let fullSAT: SAT
        let coarseFactor: Int
        let boxes: [Box]
        /// A row: the cells' median height, in pixels.
        let rowHeight: Double

        init?(reference: CGImage, zone: CGRect, cells: [CGRect]) {
            let x = Int(zone.minX.rounded())
            let y = Int(zone.minY.rounded())
            let w = Int(zone.width.rounded())
            let h = Int(zone.height.rounded())
            guard x >= 0, y >= 0, x + w <= reference.width, y + h <= reference.height, w >= 16, h >= 16,
                let plane = GreyPlane(reference)
            else { return nil }
            let boxes = cells.map { cell -> Box in
                let bx = max(0, Int((cell.minX - zone.minX).rounded()))
                let by = max(0, Int((cell.minY - zone.minY).rounded()))
                return Box(
                    x: bx, y: by, width: min(w - bx, Int(cell.width.rounded())),
                    height: min(h - by, Int(cell.height.rounded())))
            }.filter { $0.width > 0 && $0.height > 0 }
            guard !boxes.isEmpty else { return nil }
            let heights = boxes.map(\.height).sorted()
            let factor = min(w, h) >= 128 ? 8 : (min(w, h) >= 64 ? 4 : 2)
            origin = Offset(x: x, y: y)
            pyramid = Pyramid(plane.crop(x: x, y: y, width: w, height: h), coarseFactor: factor)
            halfSAT = SAT(pyramid.half)
            fullSAT = SAT(pyramid.full)
            coarseFactor = factor
            self.boxes = boxes
            rowHeight = Double(heights[heights.count / 2])
        }
    }

    fileprivate struct Score {
        let offset: Offset
        let ncc: Float
        let visible: Float
    }

    /// The part of the template (tw×th) at `offset` in the band (bw×bh) that lies in the band, in template pixels.
    private static func overlap(_ tw: Int, _ th: Int, _ bw: Int, _ bh: Int, _ offset: Offset) -> (
        x0: Int, y0: Int, x1: Int, y1: Int
    )? {
        let x0 = max(0, -offset.x)
        let y0 = max(0, -offset.y)
        let x1 = min(tw, bw - offset.x)
        let y1 = min(th, bh - offset.y)
        return x1 > x0 && y1 > y0 ? (x0, y0, x1, y1) : nil
    }

    private static func pearson(
        n: Double, st: Double, st2: Double, si: Double, si2: Double, sti: Double
    ) -> Float {
        let vt = st2 - st * st / n
        let vi = si2 - si * si / n
        guard vt > 1e-6 * n, vi > 1e-6 * n else { return 0 }
        return Float((sti - st * si / n) / (vt * vi).squareRoot())
    }

    /// Zero-mean NCC of the template over its visible part at one offset.
    private static func ncc(_ t: Grey, _ tSAT: SAT, _ b: Grey, _ bSAT: SAT, at offset: Offset) -> Score {
        guard let (x0, y0, x1, y1) = overlap(t.width, t.height, b.width, b.height, offset) else {
            return Score(offset: offset, ncc: 0, visible: 0)
        }
        let n = Double((x1 - x0) * (y1 - y0))
        let template = tSAT.sums(x0, y0, x1, y1)
        let image = bSAT.sums(x0 + offset.x, y0 + offset.y, x1 + offset.x, y1 + offset.y)
        var cross = 0.0
        t.pixels.withUnsafeBufferPointer { tp in
            b.pixels.withUnsafeBufferPointer { bp in
                for y in y0..<y1 {
                    var dot: Float = 0
                    vDSP_dotpr(
                        tp.baseAddress! + y * t.width + x0, 1,
                        bp.baseAddress! + (y + offset.y) * b.width + x0 + offset.x,
                        1, &dot, vDSP_Length(x1 - x0))
                    cross += Double(dot)
                }
            }
        }
        let value = pearson(
            n: n, st: template.sum, st2: template.squares, si: image.sum, si2: image.squares, sti: cross)
        return Score(offset: offset, ncc: value, visible: Float(n) / Float(t.width * t.height))
    }

    /// The best offset in a ±radius window around `centre`, with enough of the template in view.
    private static func refine(
        _ t: Grey, _ tSAT: SAT, _ b: Grey, _ bSAT: SAT, around centre: Offset, radius: Int
    ) -> Score? {
        var best: Score?
        for dy in -radius...radius {
            for dx in -radius...radius {
                let score = ncc(t, tSAT, b, bSAT, at: Offset(x: centre.x + dx, y: centre.y + dy))
                guard score.visible >= minVisible else { continue }
                if best.map({ score.ncc > $0.ncc }) ?? true { best = score }
            }
        }
        return best
    }

    /// The coarse NCC map over every offset with enough overlap: the cross term by `vDSP_conv` row against row, the
    /// energies from summed-area tables. The top `count` peaks after non-maximum suppression at `radius`.
    private static func coarsePeaks(_ t: Grey, _ b: Grey, minVisible: Float, radius: Int, count: Int) -> [Score] {
        let tw = t.width
        let th = t.height
        let bw = b.width
        let bh = b.height
        let paddedWidth = bw + 2 * tw
        var padded = [Float](repeating: 0, count: paddedWidth * bh)
        for y in 0..<bh {
            for x in 0..<bw { padded[y * paddedWidth + tw + x] = b.pixels[y * bw + x] }
        }
        let outWidth = paddedWidth - tw + 1
        let rows = bh + th - 1
        var cross = [Float](repeating: 0, count: outWidth * rows)
        var line = [Float](repeating: 0, count: outWidth)
        padded.withUnsafeBufferPointer { pp in
            t.pixels.withUnsafeBufferPointer { tp in
                cross.withUnsafeMutableBufferPointer { cp in
                    for r in 0..<th {
                        for y in 0..<bh {
                            vDSP_conv(
                                pp.baseAddress! + y * paddedWidth, 1, tp.baseAddress! + r * tw, 1, &line, 1,
                                vDSP_Length(outWidth), vDSP_Length(tw))
                            let row = y - r + th - 1
                            vDSP_vadd(
                                cp.baseAddress! + row * outWidth, 1, line, 1, cp.baseAddress! + row * outWidth, 1,
                                vDSP_Length(outWidth))
                        }
                    }
                }
            }
        }
        let tSAT = SAT(t)
        let bSAT = SAT(b)
        let area = Float(tw * th)
        var scored: [Score] = []
        for row in 0..<rows {
            let oy = row - (th - 1)
            for column in 0..<outWidth {
                let offset = Offset(x: column - tw, y: oy)
                guard let (x0, y0, x1, y1) = overlap(tw, th, bw, bh, offset) else { continue }
                let n = (x1 - x0) * (y1 - y0)
                guard Float(n) >= minVisible * area else { continue }
                let template = tSAT.sums(x0, y0, x1, y1)
                let image = bSAT.sums(x0 + offset.x, y0 + offset.y, x1 + offset.x, y1 + offset.y)
                let value = pearson(
                    n: Double(n), st: template.sum, st2: template.squares, si: image.sum, si2: image.squares,
                    sti: Double(cross[row * outWidth + column]))
                scored.append(Score(offset: offset, ncc: value, visible: Float(n) / area))
            }
        }
        scored.sort {
            $0.ncc != $1.ncc
                ? $0.ncc > $1.ncc : ($0.offset.y != $1.offset.y ? $0.offset.y < $1.offset.y : $0.offset.x < $1.offset.x)
        }
        var peaks: [Score] = []
        for candidate in scored where peaks.count < count {
            let near = peaks.contains {
                abs($0.offset.x - candidate.offset.x) < radius && abs($0.offset.y - candidate.offset.y) < radius
            }
            if !near { peaks.append(candidate) }
        }
        return peaks
    }

    /// The mean absolute difference of each tinted box in view between the reference and the band at `offset`.
    private static func cellCheck(_ template: Template, _ band: Grey, at offset: Offset) -> (
        visible: Int, mean: Float, worst: Float
    ) {
        let reference = template.pyramid.full
        var mads: [Float] = []
        var difference = [Float](repeating: 0, count: reference.width)
        for box in template.boxes {
            let bx = box.x + offset.x
            let by = box.y + offset.y
            guard bx >= 0, by >= 0, bx + box.width <= band.width, by + box.height <= band.height else { continue }
            var total: Float = 0
            reference.pixels.withUnsafeBufferPointer { tp in
                band.pixels.withUnsafeBufferPointer { bp in
                    for row in 0..<box.height {
                        vDSP_vsub(
                            bp.baseAddress! + (by + row) * band.width + bx, 1,
                            tp.baseAddress! + (box.y + row) * reference.width + box.x, 1, &difference, 1,
                            vDSP_Length(box.width))
                        var mean: Float = 0
                        vDSP_meamgv(difference, 1, &mean, vDSP_Length(box.width))
                        total += mean
                    }
                }
            }
            mads.append(total / Float(box.height))
        }
        guard let worst = mads.max() else { return (0, .infinity, .infinity) }
        return (mads.count, mads.reduce(0, +) / Float(mads.count), worst)
    }
}
