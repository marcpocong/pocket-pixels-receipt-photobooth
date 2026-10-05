//
//  EventHeaderImageProcessor.swift
//  PocketPixelsBooth
//

import CoreGraphics
import Foundation
import UIKit

struct EventHeaderRenderResult {
    let image: UIImage
    let frameSize: CGSize
    let sourceDrawRect: CGRect
}

enum EventHeaderQualityWarning: String, CaseIterable, Sendable {
    case lowResolution
    case veryDark
    case veryTall
    case fineDetails
    case lowContrast

    var message: String {
        switch self {
        case .lowResolution: "Low resolution — this header may print soft."
        case .veryDark: "Very dark artwork — large areas may print heavily."
        case .veryTall: "Very tall design — the header has been reduced to fit."
        case .fineDetails: "Very fine details may not reproduce clearly on thermal paper."
        case .lowContrast: "This artwork has very low contrast."
        }
    }
}

enum EventHeaderImageProcessor {
    nonisolated static let horizontalInset: CGFloat = 28
    nonisolated static let maximumPrintedHeight: CGFloat = 220
    nonisolated static let minimumPrintedHeight: CGFloat = 32
    nonisolated private static let maximumStoredDimension: CGFloat = 2_400

    nonisolated static func normalizedSourceImage(_ image: UIImage) -> UIImage {
        let pixelSize = image.cgImage.map { CGSize(width: $0.width, height: $0.height) }
            ?? CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        let downscale = min(1, maximumStoredDimension / max(pixelSize.width, pixelSize.height))
        let target = CGSize(width: max(1, floor(pixelSize.width * downscale)), height: max(1, floor(pixelSize.height * downscale)))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }

    nonisolated static func frameSize(sourceSize: CGSize, configuration: ReceiptHeaderConfiguration, receiptWidth: CGFloat = CGFloat(BoothConfiguration.receiptWidth)) -> CGSize {
        let config = configuration.normalized()
        let maximumWidth = max(1, receiptWidth - horizontalInset * 2)
        let width = min(maximumWidth, max(1, floor(maximumWidth * config.scale)))
        guard sourceSize.width > 0, sourceSize.height > 0 else { return CGSize(width: width, height: minimumPrintedHeight) }
        let naturalHeight = width * sourceSize.height / sourceSize.width
        let requestedHeight = config.layoutMode == .fit ? naturalHeight : width / 3
        let height = min(maximumPrintedHeight, max(minimumPrintedHeight, floor(requestedHeight)))
        return CGSize(width: width, height: height)
    }

    nonisolated static func renderedHeader(source: UIImage, configuration: ReceiptHeaderConfiguration, receiptWidth: CGFloat = CGFloat(BoothConfiguration.receiptWidth)) -> EventHeaderRenderResult {
        let config = configuration.normalized()
        let size = frameSize(sourceSize: source.size, configuration: config, receiptWidth: receiptWidth)
        let frame = CGRect(origin: .zero, size: size)
        let baseScale: CGFloat = config.layoutMode == .fit
            ? min(size.width / source.size.width, size.height / source.size.height)
            : max(size.width / source.size.width, size.height / source.size.height)
        let scale = baseScale * CGFloat(config.cropZoom)
        let drawSize = CGSize(width: source.size.width * scale, height: source.size.height * scale)
        let overflowX = max(0, drawSize.width - size.width)
        let overflowY = max(0, drawSize.height - size.height)
        let center = CGPoint(
            x: size.width / 2 - CGFloat(config.cropPositionX) * overflowX / 2,
            y: size.height / 2 - CGFloat(config.cropPositionY) * overflowY / 2
        )
        let drawRect = CGRect(x: center.x - drawSize.width / 2, y: center.y - drawSize.height / 2, width: drawSize.width, height: drawSize.height)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(frame)
            context.cgContext.clip(to: frame)
            context.cgContext.interpolationQuality = .high
            source.draw(in: drawRect, blendMode: .normal, alpha: 1)
        }
        return EventHeaderRenderResult(image: image, frameSize: size, sourceDrawRect: drawRect)
    }

    nonisolated static func thermalPreview(source: UIImage, configuration: ReceiptHeaderConfiguration) throws -> UIImage {
        let rendered = renderedHeader(source: source, configuration: configuration)
        let raster = try ThermalImageRasterizer.rasterize(rendered.image, purpose: .photoTest)
        guard let image = UIImage(data: raster.previewPNGData) else { throw ThermalImageRasterizerError.renderFailed }
        return image
    }

    nonisolated static func qualityWarnings(for image: UIImage, configuration: ReceiptHeaderConfiguration) -> [EventHeaderQualityWarning] {
        guard let cgImage = normalizedSourceImage(image).cgImage else { return [.lowResolution] }
        var warnings: [EventHeaderQualityWarning] = []
        let target = frameSize(sourceSize: CGSize(width: cgImage.width, height: cgImage.height), configuration: configuration)
        if CGFloat(cgImage.width) < target.width || CGFloat(cgImage.height) < target.height { warnings.append(.lowResolution) }
        if CGFloat(cgImage.height) / CGFloat(cgImage.width) > 1.4 { warnings.append(.veryTall) }
        if min(cgImage.width, cgImage.height) < 180 { warnings.append(.fineDetails) }

        let sampleWidth = 64
        let sampleHeight = max(1, Int(CGFloat(sampleWidth) * CGFloat(cgImage.height) / CGFloat(cgImage.width)))
        var pixels = [UInt8](repeating: 255, count: sampleWidth * sampleHeight * 4)
        if let context = CGContext(data: &pixels, width: sampleWidth, height: sampleHeight, bitsPerComponent: 8, bytesPerRow: sampleWidth * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            context.setFillColor(UIColor.white.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: sampleWidth, height: sampleHeight))
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: sampleWidth, height: sampleHeight))
            var values: [Double] = []
            values.reserveCapacity(sampleWidth * sampleHeight)
            for index in stride(from: 0, to: pixels.count, by: 4) {
                let alpha = Double(pixels[index + 3]) / 255
                let luminance = (0.2126 * Double(pixels[index]) + 0.7152 * Double(pixels[index + 1]) + 0.0722 * Double(pixels[index + 2])) / 255
                values.append(luminance * alpha + (1 - alpha))
            }
            let mean = values.reduce(0, +) / Double(max(1, values.count))
            let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(max(1, values.count))
            if mean < 0.28 { warnings.append(.veryDark) }
            if variance < 0.006 { warnings.append(.lowContrast) }
        }
        return warnings
    }
}
