import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Rebuilds the app icon master from the supplied artwork:
//
//   swift scripts/make-app-icon.swift Support/Icon/AppIcon-source.png Support/Icon/AppIcon.png --fit 0.8047
//
// The supplied drill artwork sits on a solid black background. This removes that matte: the black is flood-filled
// from the borders, so dark pixels inside the artwork survive, and the anti-aliased rim is rebuilt by
// un-premultiplying it against black, which is what keeps a grey fringe off the edge. --fit then scales and
// centres the artwork on Apple's icon grid (0.8047 = 824 px of art in a 1024 px canvas).
//
// scripts/bundle.sh turns the result into Hark.icns at build time; it does not run this script.

let arguments = CommandLine.arguments
guard arguments.count >= 3 else { exit(64) }
let inputURL = URL(filePath: arguments[1])
let outputURL = URL(filePath: arguments[2])
var fit: CGFloat = 1
if let index = arguments.firstIndex(of: "--fit"), index + 1 < arguments.count {
    fit = CGFloat(Double(arguments[index + 1]) ?? 1)
}

guard
    let source = NSImage(contentsOf: inputURL),
    let cgSource = source.cgImage(forProposedRect: nil, context: nil, hints: nil)
else { fatalError("cannot read \(inputURL.path)") }

let width = cgSource.width
let height = cgSource.height
var pixels = [UInt8](repeating: 0, count: width * height * 4)
guard
    let context = CGContext(
        data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
else { fatalError("cannot make context") }
context.draw(cgSource, in: CGRect(x: 0, y: 0, width: width, height: height))

func luma(_ index: Int) -> Double {
    let r = Double(pixels[index * 4]) / 255
    let g = Double(pixels[index * 4 + 1]) / 255
    let b = Double(pixels[index * 4 + 2]) / 255
    return 0.2126 * r + 0.7152 * g + 0.0722 * b
}

// 1. Flood-fill the dark background inward from every border pixel.
let matteLimit = 0.25
var isBackground = [Bool](repeating: false, count: width * height)
var queue: [Int] = []
for x in 0..<width {
    for y in [0, height - 1] where luma(y * width + x) <= matteLimit { queue.append(y * width + x) }
}
for y in 0..<height {
    for x in [0, width - 1] where luma(y * width + x) <= matteLimit { queue.append(y * width + x) }
}
for index in queue { isBackground[index] = true }
while let index = queue.popLast() {
    let x = index % width
    let y = index / width
    for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
        let nx = x + dx
        let ny = y + dy
        guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
        let neighbour = ny * width + nx
        guard !isBackground[neighbour], luma(neighbour) <= matteLimit else { continue }
        isBackground[neighbour] = true
        queue.append(neighbour)
    }
}

// 2. The outermost anti-aliased ring is above the matte limit, so the flood fill stops before it. Left alone it
// would stay opaque with its black-blended colour: a dark 1 px outline. It is matted too.
let neighbours = [(1, 0), (-1, 0), (0, 1), (0, -1)]
var isRim = [Bool](repeating: false, count: width * height)
for y in 1..<(height - 1) {
    for x in 1..<(width - 1) {
        let index = y * width + x
        guard !isBackground[index] else { continue }
        if neighbours.contains(where: { isBackground[(y + $0.1) * width + (x + $0.0)] }) {
            isRim[index] = true
        }
    }
}

// 3. Reference brightness: the first pixels the matte never touched, just inside the rim.
var edgeLumas: [Double] = []
for y in 1..<(height - 1) {
    for x in 1..<(width - 1) {
        let index = y * width + x
        guard !isBackground[index], !isRim[index] else { continue }
        if neighbours.contains(where: { isRim[(y + $0.1) * width + (x + $0.0)] }) {
            edgeLumas.append(luma(index))
        }
    }
}
edgeLumas.sort()
let referenceLuma = edgeLumas.isEmpty ? 1 : edgeLumas[edgeLumas.count / 2]

// 4. Matted pixels keep their colour and take an alpha from how much artwork bled into them: the colour is
// already the artwork multiplied by that alpha, which is what premultiplied storage expects.
var cleared = 0
for index in 0..<(width * height) where isBackground[index] || isRim[index] {
    let alpha = min(1, max(0, luma(index) / referenceLuma))
    if alpha <= 0.004 {
        pixels[index * 4] = 0
        pixels[index * 4 + 1] = 0
        pixels[index * 4 + 2] = 0
        pixels[index * 4 + 3] = 0
        cleared += 1
        continue
    }
    pixels[index * 4 + 3] = UInt8((alpha * 255).rounded())
}

guard let matted = context.makeImage() else { fatalError("cannot render") }

// 5. Optionally scale and centre the artwork on Apple's icon grid: --fit 0.8047 puts 824 px of art in 1024 px.
var minX = width, maxX = 0, minY = height, maxY = 0
for y in 0..<height {
    for x in 0..<width where pixels[(y * width + x) * 4 + 3] > 8 {
        minX = min(minX, x)
        maxX = max(maxX, x)
        minY = min(minY, y)
        maxY = max(maxY, y)
    }
}
let artWidth = CGFloat(maxX - minX + 1)
let artHeight = CGFloat(maxY - minY + 1)

guard
    let output = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
else { fatalError("cannot make output context") }
output.interpolationQuality = .high

if fit >= 1 {
    output.draw(matted, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
} else {
    let scale = CGFloat(width) * fit / max(artWidth, artHeight)
    let drawn = CGSize(width: CGFloat(width) * scale, height: CGFloat(height) * scale)
    // Put the centre of the artwork, not of the canvas, in the middle.
    // minY/maxY are buffer rows, counted from the top; the draw origin is counted from the bottom.
    let artCentre = CGPoint(
        x: (CGFloat(minX) + CGFloat(maxX) + 1) / 2,
        y: CGFloat(height) - (CGFloat(minY) + CGFloat(maxY) + 1) / 2)
    let origin = CGPoint(
        x: CGFloat(width) / 2 - artCentre.x * scale, y: CGFloat(height) / 2 - artCentre.y * scale)
    output.draw(matted, in: CGRect(origin: origin, size: drawn))
}

guard
    let result = output.makeImage(),
    let destination = CGImageDestinationCreateWithURL(outputURL as CFURL, "public.png" as CFString, 1, nil)
else { fatalError("cannot write") }
CGImageDestinationAddImage(destination, result, nil)
CGImageDestinationFinalize(destination)

let total = width * height
print(
    "reference luma \(String(format: "%.3f", referenceLuma)), fully transparent \(cleared) of \(total) px "
        + "(\(String(format: "%.1f", Double(cleared) * 100 / Double(total)))%), art \(Int(artWidth))x\(Int(artHeight)) px, fit \(fit)")
