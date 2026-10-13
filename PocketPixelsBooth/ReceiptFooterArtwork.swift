//
//  ReceiptFooterArtwork.swift
//  PocketPixelsBooth
//
//  Print artwork for the receipt's three-part footer: the official Made to Keep Studios MTK
//  monogram, prepared at exact printer-dot size, and the purely decorative barcode motif.
//

import CoreGraphics
import UIKit

/// The official MTK monogram (`MadeToKeepMonogram` asset, black ink on transparency) rasterized
/// for 1-bit thermal output.
nonisolated enum ReceiptMonogramArtwork {
    static let assetName = "MadeToKeepMonogram"
    /// Ink-bounds aspect ratio of the bundled artwork (width / height).
    static let aspectRatio: CGFloat = 837.0 / 1240.0
    /// Supersampling factor used to measure ink coverage per printer dot.
    private static let supersample = 3
    /// A dot prints when any of its sub-samples is at least this inked. Max-pooling the
    /// sub-samples keeps the script's hairlines continuous at receipt size while thick strokes
    /// grow by at most a third of a dot.
    private static let inkThreshold: UInt8 = 115

    private static let cache = MonogramCache()

    /// Pure black-and-white monogram exactly `pixelSize` dots large, or nil when the asset is
    /// missing from the bundle.
    static func image(pixelSize: CGSize) -> CGImage? {
        let width = Int(pixelSize.width.rounded()), height = Int(pixelSize.height.rounded())
        guard width > 0, height > 0 else { return nil }
        return cache.image(width: width, height: height) {
            guard let source = UIImage(named: assetName, in: .main, compatibleWith: nil)?.cgImage else { return nil }
            return rasterize(source, width: width, height: height)
        }
    }

    private static func rasterize(_ source: CGImage, width: Int, height: Int) -> CGImage? {
        let sampleWidth = width * supersample, sampleHeight = height * supersample
        // Composited on white, each sample's darkness is its ink coverage.
        var luminance = [UInt8](repeating: 255, count: sampleWidth * sampleHeight)
        let drew: Bool = luminance.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: sampleWidth, height: sampleHeight,
                                          bitsPerComponent: 8, bytesPerRow: sampleWidth, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .high
            context.draw(source, in: CGRect(x: 0, y: 0, width: sampleWidth, height: sampleHeight))
            return true
        }
        guard drew else { return nil }
        let coverage = luminance.map { 255 - $0 }

        // Opaque white paper with pure black ink: nothing for the dither to turn grey.
        var pixels = [UInt8](repeating: 255, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                var ink: UInt8 = 0
                for sy in 0..<supersample {
                    let row = (y * supersample + sy) * sampleWidth + x * supersample
                    for sx in 0..<supersample { ink = max(ink, coverage[row + sx]) }
                }
                if ink >= inkThreshold { pixels[y * width + x] = 0 }
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

private nonisolated final class MonogramCache: @unchecked Sendable {
    private let lock = NSLock()
    private var images: [String: CGImage] = [:]

    func image(width: Int, height: Int, make: () -> CGImage?) -> CGImage? {
        let key = "\(width)x\(height)"
        lock.lock()
        defer { lock.unlock() }
        if let cached = images[key] { return cached }
        let made = make()
        if let made { images[key] = made }
        return made
    }
}

/// Decorative barcode motif for the footer's left column. It encodes nothing and is not meant
/// to scan: a fixed, deterministic rhythm of whole-dot bars so every receipt and copy is identical.
nonisolated enum ReceiptDecorativeBarcode {
    /// Bar widths in printer dots, left to right.
    static let barWidths = [3, 2, 2, 5, 2, 3, 2, 2, 4, 2, 2, 3, 5, 2, 2, 3, 2, 4, 2, 2, 3, 2, 5, 3]
    /// Spaces after each bar except the last, in printer dots.
    static let gapWidths = [2, 3, 2, 2, 3, 2, 4, 2, 2, 3, 2, 2, 2, 3, 2, 2, 4, 2, 3, 2, 2, 3, 2]

    static var totalWidth: Int { barWidths.reduce(0, +) + gapWidths.reduce(0, +) }

    /// Bars filling `height` dots, starting at the given origin.
    static func bars(originX: Int, y: Int, height: Int) -> [CGRect] {
        var x = originX
        return barWidths.enumerated().map { index, width in
            defer { x += width + (index < gapWidths.count ? gapWidths[index] : 0) }
            return CGRect(x: x, y: y, width: width, height: height)
        }
    }
}
