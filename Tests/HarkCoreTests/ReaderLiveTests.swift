import CoreGraphics
import Foundation
import ImageIO
import Testing
import os

@testable import HarkCore

/// The live bench, opt-in: `HARK_TEST_READER_CASES=<dir>` reads every `<dir>/<case>/region.png` with Vision and writes
/// the measurement's JSON shape (`tables`, `lines`, `info`) to `HARK_TEST_READER_OUT`, for `score_reading`.
/// `HARK_TEST_READER_RECORD=1` also writes every rung's read of every crop. Nothing else is written.
@Suite struct ReaderLiveTests {
    private struct CropRead: Sendable {
        var box: CGRect
        var rung: Rung
        var text: String
    }

    private static let environment = ProcessInfo.processInfo.environment

    @available(macOS 26, *)
    @Test(.enabled(if: environment["HARK_TEST_READER_CASES"] != nil), .timeLimit(.minutes(5)))
    func theReaderReadsTheMeasurementsCases() async throws {
        let root = URL(filePath: try #require(Self.environment["HARK_TEST_READER_CASES"]))
        let out = URL(filePath: try #require(Self.environment["HARK_TEST_READER_OUT"]))
        let record = Self.environment["HARK_TEST_READER_RECORD"] == "1"
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path(percentEncoded: false)).sorted()
        var times: [Int] = []
        for name in names {
            let png = root.appending(path: name).appending(path: "region.png")
            guard FileManager.default.fileExists(atPath: png.path(percentEncoded: false)) else { continue }
            let image = try Self.load(png)
            let crops = OSAllocatedUnfairLock(initialState: [CropRead]())
            var hook: (@Sendable (CGRect, Rung, String) -> Void)?
            if record {
                hook = { box, rung, text in crops.withLock { $0.append(CropRead(box: box, rung: rung, text: text)) } }
            }
            let reader = VisionRegionReader(recognizer: VisionTextRecognizer(), onCrop: hook)
            let sheet = try await reader.read(RegionRaster(image: image)).get()
            times.append(sheet.readMs)
            var json = Self.reading(sheet)
            if record {
                json["crops"] = crops.withLock { $0 }.map {
                    ["box": Self.array($0.box), "rung": $0.rung.description, "text": $0.text] as [String: Any]
                }
            }
            let data = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
            try data.write(to: out.appending(path: "\(name).json"))
        }
        #expect(!times.isEmpty)
    }

    /// The measurement's Vision-shaped JSON: every table's cells with their row and column, then the free lines.
    private static func reading(_ sheet: CellSheet) -> [String: Any] {
        let tables = Set(sheet.cells.compactMap(\.table)).sorted()
        return [
            "tables": tables.map { table in
                [
                    "box": [0, 0, 0, 0],
                    "cells": sheet.cells.filter { $0.table == table }.map { cell -> [String: Any] in
                        ["r": cell.row ?? 0, "c": cell.column ?? 0, "text": cell.text, "box": array(cell.box)]
                    },
                ] as [String: Any]
            },
            "lines": sheet.cells.filter { $0.table == nil }.map { ["text": $0.text, "box": array($0.box)] },
            "info": ["ms": sheet.readMs, "uncertain": sheet.cells.filter(\.suspicious).count],
        ]
    }

    private static func array(_ box: CGRect) -> [CGFloat] {
        [box.origin.x, box.origin.y, box.size.width, box.size.height]
    }

    /// The PNG decoded in memory and drawn into sRGB, as the app's encoder does.
    private static func load(_ url: URL) throws -> CGImage {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let srgb = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(
            CGContext(
                data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return try #require(context.makeImage())
    }
}
