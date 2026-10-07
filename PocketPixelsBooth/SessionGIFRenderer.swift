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
    private static let minimumLongestSide = 360

    static func render(images: [UIImage]) throws -> Data {
        guard !images.isEmpty else { throw SessionGIFRendererError.noFrames }
        var longestSide = maximumLongestSide
        while longestSide >= minimumLongestSide {
            let frames = try images.map { try normalizedFrame($0, maximumLongestSide: longestSide) }
            let data = try encode(frames: frames)
            if data.count <= maximumByteCount { return data }
            longestSide = Int(Double(longestSide) * 0.78)
        }
        throw SessionGIFRendererError.sizeLimitExceeded
    }

    private static func normalizedFrame(_ image: UIImage, maximumLongestSide: Int) throws -> CGImage {
        guard image.size.width > 0, image.size.height > 0 else { throw SessionGIFRendererError.encodingFailed }
        let scale = min(1, CGFloat(maximumLongestSide) / max(image.size.width, image.size.height))
        let size = CGSize(width: max(1, floor(image.size.width * scale)), height: max(1, floor(image.size.height * scale)))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let normalized = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let cgImage = normalized.cgImage else { throw SessionGIFRendererError.encodingFailed }
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
        return data as Data
    }
}
