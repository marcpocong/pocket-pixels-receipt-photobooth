import ImageIO
import UIKit
import UniformTypeIdentifiers

enum SessionGIFRendererError: Error, LocalizedError {
    case noFrames
    case encodingFailed
    case sizeLimitExceeded

    var errorDescription: String? {
        switch self {
        case .noFrames: "A session GIF needs at least one photo."
        case .encodingFailed: "The session GIF could not be created."
        case .sizeLimitExceeded: "The session GIF could not be reduced to the gallery size limit."
        }
    }
}

nonisolated enum SessionGIFRenderer {
    static let frameDelay = 0.7
    static let maximumLongestSide = 840
    static let maximumByteCount = 2 * 1024 * 1024
    static let canvasBackgroundColor = UIColor(red: 247 / 255, green: 241 / 255, blue: 233 / 255, alpha: 1)
    private static let minimumLongestSide = 240

    static func render(images: [UIImage], maximumByteCount: Int = maximumByteCount) throws -> Data {
        guard !images.isEmpty else { throw SessionGIFRendererError.noFrames }
        guard maximumByteCount >= GalleryPreparedUploadBudget.minimumGIFByteBudget else {
            throw SessionGIFRendererError.sizeLimitExceeded
        }
        var canvasSide = maximumLongestSide
        while canvasSide >= minimumLongestSide {
            let frames = try images.map { try normalizedFrame($0, canvasSide: canvasSide) }
            let data = try encode(frames: frames)
            if data.count <= maximumByteCount { return data }
            let nextSide = Int(Double(canvasSide) * 0.78)
            canvasSide = min(canvasSide - 1, nextSide)
        }
        throw SessionGIFRendererError.sizeLimitExceeded
    }

    private static func normalizedFrame(_ image: UIImage, canvasSide: Int) throws -> CGImage {
        guard image.size.width > 0, image.size.height > 0 else { throw SessionGIFRendererError.encodingFailed }
        let normalized = image.normalizedForGalleryUpload()
        let canvasSize = CGSize(width: canvasSide, height: canvasSide)
        let scale = min(CGFloat(canvasSide) / normalized.size.width, CGFloat(canvasSide) / normalized.size.height)
        let drawSize = CGSize(width: floor(normalized.size.width * scale), height: floor(normalized.size.height * scale))
        let drawRect = CGRect(
            x: floor((canvasSize.width - drawSize.width) / 2),
            y: floor((canvasSize.height - drawSize.height) / 2),
            width: drawSize.width,
            height: drawSize.height
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let frame = UIGraphicsImageRenderer(size: canvasSize, format: format).image { context in
            canvasBackgroundColor.setFill()
            context.fill(CGRect(origin: .zero, size: canvasSize))
            normalized.draw(in: drawRect)
        }
        guard let cgImage = frame.cgImage else { throw SessionGIFRendererError.encodingFailed }
        return cgImage
    }

    private static func encode(frames: [CGImage]) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, frames.count, nil) else {
            throw SessionGIFRendererError.encodingFailed
        }
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let properties = [kCGImagePropertyGIFDictionary: [
            kCGImagePropertyGIFDelayTime: frameDelay,
            kCGImagePropertyGIFUnclampedDelayTime: frameDelay
        ]] as CFDictionary
        for frame in frames { CGImageDestinationAddImage(destination, frame, properties) }
        guard CGImageDestinationFinalize(destination) else { throw SessionGIFRendererError.encodingFailed }
        // ImageIO can label otherwise valid animated output GIF87a. The delay/loop extensions
        // require the GIF89a revision marker, and the two revisions share the same header layout.
        if data.length >= 6 {
            data.replaceBytes(in: NSRange(location: 0, length: 6), withBytes: Array("GIF89a".utf8))
        }
        return data as Data
    }
}
