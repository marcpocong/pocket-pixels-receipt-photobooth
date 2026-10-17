//
//  MonochromeReceiptRenderer.swift
//  PocketPixelsBooth
//
//  Customer-facing black & white receipt treatment: a smooth 8-bit grayscale copy of an already
//  composed receipt for iPad screens, the QR gallery and saved/shared files. It is presentation
//  only. Physical printing always uses ThermalImageRasterizer's 1-bit raster, never this image.
//

import ImageIO
import UIKit
import UniformTypeIdentifiers

nonisolated enum MonochromeReceiptRendererError: Error, LocalizedError {
    case renderFailed
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .renderFailed: "The black & white receipt preview could not be rendered."
        case .encodingFailed: "The black & white receipt preview could not be encoded."
        }
    }
}

nonisolated struct MonochromeReceipt: Sendable {
    let image: UIImage
    /// 8-bit grayscale PNG (IHDR color type 0, depth 8). The gallery backend relies on this
    /// signature to tell these smooth previews apart from legacy 1-bit printer rasters.
    let pngData: Data
    let width: Int
    let height: Int
}

nonisolated enum MonochromeReceiptRenderer {
    /// Integer Rec. 709 luma weights (sum 256) applied to sRGB values. The gallery's legacy
    /// fallback (`Code.gs`) uses identical math so old and new galleries look the same.
    static let lumaWeights: (red: Int, green: Int, blue: Int) = (54, 183, 19)
    /// Restrained photographic contrast around mid-gray. White paper stays white, black stays black.
    static let contrast = 1.05

    static let toneCurve: [UInt8] = (0...255).map { value in
        let adjusted = (Double(value) - 127.5) * contrast + 127.5
        return UInt8(min(255, max(0, adjusted.rounded())))
    }

    /// Converts `image` without resizing, cropping or moving anything. Orientation is baked in,
    /// transparency is flattened onto white paper and the pixel dimensions are preserved.
    static func render(_ image: UIImage) throws -> MonochromeReceipt {
        try autoreleasepool {
            let pixelWidth = Int((image.size.width * image.scale).rounded())
            let pixelHeight = Int((image.size.height * image.scale).rounded())
            guard pixelWidth > 0, pixelHeight > 0 else { throw MonochromeReceiptRendererError.renderFailed }

            var rgba = [UInt8](repeating: 255, count: pixelWidth * pixelHeight * 4)
            guard let srgb = CGColorSpace(name: CGColorSpace.sRGB) else { throw MonochromeReceiptRendererError.renderFailed }
            try rgba.withUnsafeMutableBytes { buffer in
                guard let context = CGContext(
                    data: buffer.baseAddress,
                    width: pixelWidth,
                    height: pixelHeight,
                    bitsPerComponent: 8,
                    bytesPerRow: pixelWidth * 4,
                    space: srgb,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
                ) else { throw MonochromeReceiptRendererError.renderFailed }
                context.setFillColor(UIColor.white.cgColor)
                context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
                context.interpolationQuality = .none
                // UIKit drawing applies the image orientation; flip into UIKit coordinates.
                context.translateBy(x: 0, y: CGFloat(pixelHeight))
                context.scaleBy(x: 1, y: -1)
                UIGraphicsPushContext(context)
                image.draw(in: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
                UIGraphicsPopContext()
            }

            var gray = [UInt8](repeating: 255, count: pixelWidth * pixelHeight)
            let curve = toneCurve
            let weights = lumaWeights
            for index in 0..<(pixelWidth * pixelHeight) {
                let offset = index * 4
                let luma = (weights.red * Int(rgba[offset]) + weights.green * Int(rgba[offset + 1])
                    + weights.blue * Int(rgba[offset + 2]) + 128) >> 8
                gray[index] = curve[min(255, luma)]
            }

            let cgImage: CGImage = try gray.withUnsafeMutableBytes { buffer in
                guard let context = CGContext(
                    data: buffer.baseAddress,
                    width: pixelWidth,
                    height: pixelHeight,
                    bitsPerComponent: 8,
                    bytesPerRow: pixelWidth,
                    space: CGColorSpaceCreateDeviceGray(),
                    bitmapInfo: CGImageAlphaInfo.none.rawValue
                ), let made = context.makeImage() else { throw MonochromeReceiptRendererError.renderFailed }
                return made
            }

            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
                throw MonochromeReceiptRendererError.encodingFailed
            }
            CGImageDestinationAddImage(destination, cgImage, nil)
            guard CGImageDestinationFinalize(destination) else { throw MonochromeReceiptRendererError.encodingFailed }

            return MonochromeReceipt(
                image: UIImage(cgImage: cgImage, scale: 1, orientation: .up),
                pngData: data as Data,
                width: pixelWidth,
                height: pixelHeight
            )
        }
    }

    /// True for an 8-bit grayscale PNG produced by this renderer; false for legacy printer rasters.
    static func isSmoothMonochromePNG(_ data: Data) -> Bool {
        let bytes = [UInt8](data.prefix(26))
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        guard bytes.count == 26, Array(bytes[0..<8]) == signature, Array(bytes[12..<16]) == Array("IHDR".utf8) else { return false }
        return bytes[24] == 8 && bytes[25] == 0
    }
}
