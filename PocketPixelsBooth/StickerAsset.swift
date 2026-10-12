//
//  StickerAsset.swift
//  PocketPixelsBooth
//
//  Sticker catalog entries, their provenance, and the bounded ImageIO decoder every sticker
//  image (bundled, imported or downloaded) goes through before it can be shown or printed.
//

import CoreGraphics
import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

nonisolated enum StickerSourceKind: String, Codable, Sendable {
    case builtIn
    case operatorImport
    case online
}

/// Where a sticker came from and why it may be printed. Kept with each frozen placement.
nonisolated struct StickerProvenance: Codable, Hashable, Sendable {
    var source: StickerSourceKind
    /// e.g. "GIPHY" for online content; nil for local sources.
    var provider: String?
    var providerContentID: String?
    /// Public creator display name supplied by the provider, if any.
    var creatorAttribution: String?
    var rightsBasis: String

    static let builtIn = StickerProvenance(source: .builtIn, rightsBasis: "Original Made to Keep Studios artwork")
    static let operatorImport = StickerProvenance(source: .operatorImport, rightsBasis: "Operator-approved import")
}

nonisolated struct StickerAsset: Identifiable, Equatable, Sendable {
    let id: String
    var name: String
    var tags: [String]
    var category: StickerCategory
    var provenance: StickerProvenance
    var isAnimated = false
    var frameCount = 1
    /// width / height of the source artwork.
    var aspectRatio: CGFloat = 1
    var isInEventCollection = false
    /// Operator-facing warning (e.g. low contrast). Never blocks a guest.
    var printWarning: String?

    /// Offline search over name, category and tags.
    func matches(_ query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return true }
        let haystack = ([name, category.displayName] + tags).joined(separator: " ").lowercased()
        return needle.split(separator: " ").allSatisfy { haystack.contains($0) }
    }

    /// The still frame that prints for an animated sticker unless the guest picks another.
    var representativeFrameIndex: Int {
        frameCount > 1 ? frameCount / 2 : 0
    }
}

// MARK: - Limits

/// Tunable safety caps for every sticker image. Tests pin these values.
nonisolated enum StickerImageLimits {
    static let maximumImportBytes = 5 * 1024 * 1024
    static let maximumRemoteBytes = 5 * 1024 * 1024
    /// Any source dimension above this is rejected before decoding.
    static let maximumSourcePixelDimension = 8_192
    static let maximumSourcePixelArea = 36_000_000
    /// Decoded sticker artwork is bounded to this edge length (2048 × 2048 total bounding).
    static let maximumDecodedPixelDimension = 2_048
    /// Print artwork never needs more: the largest sticker covers one 504-dot photo.
    static let printPixelDimension = 768
    static let thumbnailPixelDimension = 320
    static let maximumFrameCount = 400
    static let maximumConcurrentDownloads = 3

    static let acceptedTypeIdentifiers: Set<String> = [UTType.png.identifier, UTType.jpeg.identifier, UTType.gif.identifier]
}

nonisolated enum StickerImageError: Error, LocalizedError, Equatable {
    case empty
    case tooLarge
    case unsupportedType
    case dimensionsTooLarge
    case decodeFailed
    case frameOutOfRange

    var errorDescription: String? {
        switch self {
        case .empty: "The file is empty."
        case .tooLarge: "The file is larger than \(StickerImageLimits.maximumImportBytes / 1_048_576) MB."
        case .unsupportedType: "Only PNG, JPEG and GIF images can be used as stickers."
        case .dimensionsTooLarge: "The image dimensions are too large."
        case .decodeFailed: "The image could not be read."
        case .frameOutOfRange: "That frame does not exist in this image."
        }
    }
}

nonisolated struct StickerImageInfo: Equatable, Sendable {
    let typeIdentifier: String
    let pixelWidth: Int
    let pixelHeight: Int
    let frameCount: Int

    var isAnimated: Bool { frameCount > 1 }
    var aspectRatio: CGFloat { pixelHeight > 0 ? CGFloat(pixelWidth) / CGFloat(pixelHeight) : 1 }
    var fileExtension: String {
        switch typeIdentifier {
        case UTType.png.identifier: "png"
        case UTType.jpeg.identifier: "jpg"
        default: "gif"
        }
    }
}

/// Bounded, deterministic ImageIO decoding. The same bytes and frame index always produce the
/// same pixels, so reprints and copies never drift.
nonisolated enum StickerImageDecoder {
    static func inspect(_ data: Data, maximumBytes: Int = StickerImageLimits.maximumImportBytes) throws -> StickerImageInfo {
        guard !data.isEmpty else { throw StickerImageError.empty }
        guard data.count <= maximumBytes else { throw StickerImageError.tooLarge }
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options),
              let type = CGImageSourceGetType(source) as String? else {
            throw StickerImageError.decodeFailed
        }
        guard StickerImageLimits.acceptedTypeIdentifiers.contains(type) else { throw StickerImageError.unsupportedType }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { throw StickerImageError.decodeFailed }
        guard count <= StickerImageLimits.maximumFrameCount else { throw StickerImageError.dimensionsTooLarge }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0 else {
            throw StickerImageError.decodeFailed
        }
        guard width <= StickerImageLimits.maximumSourcePixelDimension,
              height <= StickerImageLimits.maximumSourcePixelDimension,
              width * height <= StickerImageLimits.maximumSourcePixelArea else {
            throw StickerImageError.dimensionsTooLarge
        }
        // EXIF orientation 5–8 swaps the displayed axes.
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let swapsAxes = (5...8).contains(orientation)
        return StickerImageInfo(
            typeIdentifier: type,
            pixelWidth: swapsAxes ? height : width,
            pixelHeight: swapsAxes ? width : height,
            frameCount: count
        )
    }

    /// Decodes one frame, orientation-corrected, bounded to `maximumPixelDimension`, and redrawn
    /// into an 8-bit sRGB RGBA bitmap.
    static func decodeFrame(
        _ data: Data,
        frameIndex: Int = 0,
        maximumPixelDimension: Int = StickerImageLimits.printPixelDimension,
        maximumBytes: Int = StickerImageLimits.maximumImportBytes
    ) throws -> CGImage {
        let info = try inspect(data, maximumBytes: maximumBytes)
        guard (0..<info.frameCount).contains(frameIndex) else { throw StickerImageError.frameOutOfRange }
        let bound = min(max(1, maximumPixelDimension), StickerImageLimits.maximumDecodedPixelDimension)
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw StickerImageError.decodeFailed
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: bound
        ]
        guard let decoded = CGImageSourceCreateThumbnailAtIndex(source, frameIndex, options as CFDictionary) else {
            throw StickerImageError.decodeFailed
        }
        return try redrawnRGBA(decoded)
    }

    static func redrawnRGBA(_ image: CGImage) throws -> CGImage {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0,
              width <= StickerImageLimits.maximumDecodedPixelDimension,
              height <= StickerImageLimits.maximumDecodedPixelDimension,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            throw StickerImageError.decodeFailed
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let result = context.makeImage() else { throw StickerImageError.decodeFailed }
        return result
    }
}

// MARK: - Print preparation

/// Turns any sticker artwork into receipt-ready ink: grayscale, with alpha snapped to fully
/// opaque or fully clear so partial transparency never turns into a grey haze after dithering.
nonisolated enum StickerPrintPreparation {
    static let alphaThreshold: UInt8 = 128

    static func prepare(_ image: CGImage) throws -> CGImage {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            throw StickerImageError.decodeFailed
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let buffer = context.data else { throw StickerImageError.decodeFailed }
        let pixels = buffer.bindMemory(to: UInt8.self, capacity: width * height * 4)
        for index in 0..<(width * height) {
            let offset = index * 4
            let alpha = pixels[offset + 3]
            guard alpha >= alphaThreshold else {
                pixels[offset] = 0; pixels[offset + 1] = 0; pixels[offset + 2] = 0; pixels[offset + 3] = 0
                continue
            }
            // Un-premultiply, then luminance.
            let scale = 255.0 / Double(alpha)
            let red = Double(pixels[offset]) * scale
            let green = Double(pixels[offset + 1]) * scale
            let blue = Double(pixels[offset + 2]) * scale
            let luminance = UInt8(max(0, min(255, (0.299 * red + 0.587 * green + 0.114 * blue).rounded())))
            pixels[offset] = luminance
            pixels[offset + 1] = luminance
            pixels[offset + 2] = luminance
            pixels[offset + 3] = 255
        }
        guard let result = context.makeImage() else { throw StickerImageError.decodeFailed }
        return result
    }

    /// Spread between dark and light ink in the visible pixels (0–255). Below ~70 a sticker
    /// usually prints as a muddy blob.
    static func contrastSpread(of image: CGImage) -> Int {
        guard let prepared = try? prepare(image),
              let data = prepared.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else { return 0 }
        let bytesPerRow = prepared.bytesPerRow
        var histogram = [Int](repeating: 0, count: 256)
        var visible = 0
        for y in stride(from: 0, to: prepared.height, by: 2) {
            for x in stride(from: 0, to: prepared.width, by: 2) {
                let offset = y * bytesPerRow + x * 4
                guard bytes[offset + 3] == 255 else { continue }
                histogram[Int(bytes[offset])] += 1
                visible += 1
            }
        }
        guard visible > 0 else { return 0 }
        func percentile(_ fraction: Double) -> Int {
            let target = Int(Double(visible) * fraction)
            var running = 0
            for (value, count) in histogram.enumerated() {
                running += count
                if running > target { return value }
            }
            return 255
        }
        return percentile(0.95) - percentile(0.05)
    }

    static let lowContrastThreshold = 70
    static let lowContrastWarning = "Low contrast — this may print as a grey blur."
}
