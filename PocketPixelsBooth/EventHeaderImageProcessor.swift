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
        guard sourceSize.width.isFinite, sourceSize.height.isFinite,
              sourceSize.width > 0, sourceSize.height > 0 else {
            return CGSize(width: width, height: minimumPrintedHeight)
        }
        let naturalHeight = width * sourceSize.height / sourceSize.width
        let requestedHeight = config.layoutMode == .fit ? naturalHeight : width * config.effectiveFillHeightRatio
        let height = min(maximumPrintedHeight, max(minimumPrintedHeight, floor(requestedHeight)))
        return CGSize(width: width, height: height)
    }

    /// Placement of the artwork frame on the receipt. Shared by ReceiptComposer and the editor so
    /// the editor canvas is pixel-identical to the printed header.
    nonisolated static func frameRect(
        sourceSize: CGSize,
        configuration: ReceiptHeaderConfiguration,
        y: CGFloat,
        receiptWidth: CGFloat = CGFloat(BoothConfiguration.receiptWidth)
    ) -> CGRect {
        let size = frameSize(sourceSize: sourceSize, configuration: configuration, receiptWidth: receiptWidth)
        let available = max(0, receiptWidth - horizontalInset * 2 - size.width)
        let position = configuration.normalized().effectiveHorizontalPosition
        let x = horizontalInset + available * CGFloat(position + 1) / 2
        return CGRect(x: floor(x), y: y, width: size.width, height: size.height)
    }

    nonisolated static func renderedHeader(source: UIImage, configuration: ReceiptHeaderConfiguration, receiptWidth: CGFloat = CGFloat(BoothConfiguration.receiptWidth)) -> EventHeaderRenderResult {
        renderedHeader(source: EventArtwork(image: source), configuration: configuration, receiptWidth: receiptWidth)
    }

    /// Renders the artwork into its frame on opaque white paper. Transparent artwork composites
    /// against white here, before any thermal conversion.
    nonisolated static func renderedHeader(source: EventArtwork, configuration: ReceiptHeaderConfiguration, receiptWidth: CGFloat = CGFloat(BoothConfiguration.receiptWidth)) -> EventHeaderRenderResult {
        let config = configuration.normalized()
        let size = frameSize(sourceSize: source.size, configuration: config, receiptWidth: receiptWidth)
        return renderedArtwork(source: source, configuration: config, frameSize: size)
    }

    // MARK: Bottom signature (Studio-First)

    /// The signature stays well inside the printable width so wide banners scale down naturally
    /// and never read as a second masthead.
    nonisolated static let signatureMaximumWidth: CGFloat = 320
    nonisolated static let signatureMaximumHeight: CGFloat = 100
    nonisolated static let signatureMinimumHeight: CGFloat = 24

    /// Compact, aspect-preserving frame for artwork printed near the bottom of a receipt. Fit
    /// artwork uses its own proportions (so monograms stay small); Fill uses the banner ratio.
    /// The editor's size control scales the signature within its maximum box.
    nonisolated static func signatureFrameSize(sourceSize: CGSize, configuration: ReceiptHeaderConfiguration) -> CGSize {
        let config = configuration.normalized()
        let scale = CGFloat(min(config.scale, ReceiptHeaderConfiguration.maximumEditorScale))
        let maximumWidth = floor(signatureMaximumWidth * scale)
        guard sourceSize.width.isFinite, sourceSize.height.isFinite,
              sourceSize.width > 0, sourceSize.height > 0 else {
            return CGSize(width: maximumWidth, height: signatureMinimumHeight)
        }
        let aspect = config.layoutMode == .fit
            ? sourceSize.height / sourceSize.width
            : CGFloat(config.effectiveFillHeightRatio)
        var width = maximumWidth
        var height = width * aspect
        if height > signatureMaximumHeight {
            height = signatureMaximumHeight
            width = height / aspect
        }
        return CGSize(width: max(1, floor(width)), height: max(signatureMinimumHeight, floor(height)))
    }

    /// Centered signature frame starting at `y`.
    nonisolated static func signatureFrameRect(
        sourceSize: CGSize,
        configuration: ReceiptHeaderConfiguration,
        y: CGFloat,
        receiptWidth: CGFloat = CGFloat(BoothConfiguration.receiptWidth)
    ) -> CGRect {
        let size = signatureFrameSize(sourceSize: sourceSize, configuration: configuration)
        return CGRect(x: floor((receiptWidth - size.width) / 2), y: y, width: size.width, height: size.height)
    }

    nonisolated static func renderedSignature(source: EventArtwork, configuration: ReceiptHeaderConfiguration) -> EventHeaderRenderResult {
        let config = configuration.normalized()
        return renderedArtwork(source: source, configuration: config, frameSize: signatureFrameSize(sourceSize: source.size, configuration: config))
    }

    /// True when a tall logo had to be reduced to fit the signature's maximum height.
    nonisolated static func signatureIsHeightConstrained(sourceSize: CGSize, configuration: ReceiptHeaderConfiguration) -> Bool {
        let config = configuration.normalized()
        guard config.layoutMode == .fit, sourceSize.width > 0, sourceSize.height > 0 else { return false }
        let scale = CGFloat(min(config.scale, ReceiptHeaderConfiguration.maximumEditorScale))
        return floor(signatureMaximumWidth * scale) * sourceSize.height / sourceSize.width > signatureMaximumHeight * 1.4
    }

    /// Renders artwork into an exact frame size on opaque white paper.
    nonisolated static func renderedArtwork(source: EventArtwork, configuration config: ReceiptHeaderConfiguration, frameSize size: CGSize) -> EventHeaderRenderResult {
        let frame = CGRect(origin: .zero, size: size)
        let drawRect = sourceDrawRect(sourceSize: source.size, frameSize: size, configuration: config)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(frame)
            context.cgContext.clip(to: frame)
            context.cgContext.interpolationQuality = .high
            source.draw(in: drawRect, context: context.cgContext)
        }
        return EventHeaderRenderResult(image: image, frameSize: size, sourceDrawRect: drawRect)
    }

    /// Where the artwork is drawn inside its frame for the given fit, zoom and crop position.
    nonisolated static func sourceDrawRect(sourceSize: CGSize, frameSize size: CGSize, configuration: ReceiptHeaderConfiguration) -> CGRect {
        let config = configuration.normalized()
        guard sourceSize.width > 0, sourceSize.height > 0 else { return CGRect(origin: .zero, size: size) }
        let baseScale: CGFloat = config.layoutMode == .fit
            ? min(size.width / sourceSize.width, size.height / sourceSize.height)
            : max(size.width / sourceSize.width, size.height / sourceSize.height)
        let scale = baseScale * CGFloat(config.cropZoom)
        let drawSize = CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
        let overflowX = max(0, drawSize.width - size.width)
        let overflowY = max(0, drawSize.height - size.height)
        let center = CGPoint(
            x: size.width / 2 - CGFloat(config.cropPositionX) * overflowX / 2,
            y: size.height / 2 - CGFloat(config.cropPositionY) * overflowY / 2
        )
        return CGRect(x: center.x - drawSize.width / 2, y: center.y - drawSize.height / 2, width: drawSize.width, height: drawSize.height)
    }

    /// The header band exactly as it appears at the top of the receipt: full 576-dot width,
    /// top spacing, the rendered frame, and bottom spacing on white paper.
    nonisolated static func receiptStrip(source: EventArtwork, configuration: ReceiptHeaderConfiguration) -> (image: UIImage, frame: CGRect) {
        let config = configuration.normalized()
        let width = CGFloat(BoothConfiguration.receiptWidth)
        let top = CGFloat(Int(config.topSpacing.rounded()))
        let frame = frameRect(sourceSize: source.size, configuration: config, y: top, receiptWidth: width)
        let height = top + frame.height + CGFloat(Int(config.bottomSpacing.rounded()))
        let rendered = renderedHeader(source: source, configuration: config, receiptWidth: width)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: CGSize(width: width, height: max(1, height)), format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: max(1, height)))
            rendered.image.draw(in: frame)
        }
        return (image, frame)
    }

    nonisolated static func thermalPreview(source: UIImage, configuration: ReceiptHeaderConfiguration) throws -> UIImage {
        try thermalPreview(source: EventArtwork(image: source), configuration: configuration)
    }

    /// Thermal view of the header band using the production complete-receipt rasterizer. The band
    /// starts on white paper, so its dithering matches the same rows of a printed receipt.
    nonisolated static func thermalPreview(source: EventArtwork, configuration: ReceiptHeaderConfiguration) throws -> UIImage {
        let strip = receiptStrip(source: source, configuration: configuration).image
        let raster = try ThermalImageRasterizer.rasterize(strip, purpose: .completeReceipt)
        guard let image = UIImage(data: raster.previewPNGData) else { throw ThermalImageRasterizerError.renderFailed }
        return image
    }

    /// Vector artwork has no source resolution limit, so resolution-based warnings are skipped.
    nonisolated static func qualityWarnings(for artwork: EventArtwork, configuration: ReceiptHeaderConfiguration) -> [EventHeaderQualityWarning] {
        switch artwork.kind {
        case .bitmap:
            return qualityWarnings(for: artwork.image(), configuration: configuration)
        case .vector:
            let sample = artwork.image(fitting: 1_200)
            return qualityWarnings(for: sample, configuration: configuration)
                .filter { $0 != .lowResolution && $0 != .fineDetails }
        }
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
