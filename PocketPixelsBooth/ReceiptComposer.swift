//
//  ReceiptComposer.swift
//  PocketPixelsBooth
//

import Foundation
import UIKit

struct ComposedReceipt: Sendable {
    let imagePNGData: Data
    let width: Int
    let height: Int
    let previewContentHeight: Int
    let sessionIdentifier: String
    let createdAt: Date
    let format: BoothFormat

    var estimatedLengthMillimeters: Double {
        Double(height) / 8.0
    }
}

struct ReceiptPhotoFrame: Sendable {
    let photoIndex: Int
    let rect: CGRect
}

struct ReceiptLayoutPlan: Sendable {
    let format: BoothFormat
    let displayedPhotoIndexes: [Int]
    let photoFrames: [ReceiptPhotoFrame]
    let groupFrame: CGRect?
    let width: Int
    let height: Int
    let previewContentHeight: Int
    let qrSize: Int
}

enum ReceiptComposerError: Error, LocalizedError {
    case missingPhotos(expected: Int, actual: Int)
    case renderFailed
    case heightExceeded(Int)

    var errorDescription: String? {
        switch self {
        case .missingPhotos(let expected, let actual):
            "Receipt requires \(expected) photos, but \(actual) are available."
        case .renderFailed:
            "The receipt could not be rendered."
        case .heightExceeded(let height):
            "The composed receipt is too tall: \(height) pixels."
        }
    }
}

enum ReceiptComposer {
    nonisolated static let sessionIdentifierTimeZone = TimeZone(identifier: "Asia/Manila") ?? TimeZone(secondsFromGMT: 8 * 60 * 60)!
    nonisolated static let receiptQRCodeSize = 192
    nonisolated static let landscapePresentationCropAspectRatio = CGSize(width: 4, height: 3)
    nonisolated static let landscapePresentationAspectRatio = landscapePresentationCropAspectRatio.width / landscapePresentationCropAspectRatio.height
    nonisolated static let stripPresentationCropAspectRatio = landscapePresentationCropAspectRatio
    nonisolated private static let footerTopDividerPadding = 10
    nonisolated private static let footerContentTopPadding = 10
    nonisolated private static let footerContentBottomPadding = 10
    nonisolated private static let footerBottomPadding = 14
    nonisolated private static let footerColumnGutter = 20

    nonisolated static func makeSessionIdentifier(date: Date = Date()) -> String {
        "PP-\(identifierFormatter.string(from: date))"
    }

    nonisolated static func compose(
        photos: [UIImage],
        sessionIdentifier: String,
        date: Date = Date(),
        galleryURL: URL? = nil,
        format: BoothFormat
    ) throws -> ComposedReceipt {
        guard photos.count == format.photoCount else {
            throw ReceiptComposerError.missingPhotos(expected: format.photoCount, actual: photos.count)
        }

        let plan = try makeLayoutPlan(format: format, includesGalleryQRCode: galleryURL != nil)
        let width = BoothConfiguration.receiptWidth
        let margin = BoothConfiguration.receiptHorizontalMargin
        let height = plan.height

        guard height <= BoothConfiguration.receiptMaximumHeight else {
            throw ReceiptComposerError.heightExceeded(height)
        }

        let rendererFormat = UIGraphicsImageRendererFormat()
        rendererFormat.scale = 1
        rendererFormat.opaque = true

        let size = CGSize(width: width, height: height)
        let renderer = UIGraphicsImageRenderer(size: size, format: rendererFormat)
        let image = renderer.image { context in
            let cgContext = context.cgContext
            UIColor.white.setFill()
            cgContext.fill(CGRect(origin: .zero, size: size))

            var y = 14
            drawCentered("POCKET PIXELS", y: y, width: width, font: .systemFont(ofSize: 30, weight: .bold))
            y += 34
            drawCentered("RECEIPT PHOTOBOOTH", y: y, width: width, font: .systemFont(ofSize: 16, weight: .semibold))
            y += 26
            drawDivider(y: y, margin: margin, width: width)

            if let groupFrame = plan.groupFrame {
                UIColor.black.setStroke()
                cgContext.setLineWidth(2)
                cgContext.stroke(groupFrame.insetBy(dx: 1, dy: 1))
            }

            for frame in plan.photoFrames {
                drawPhoto(
                    photos[frame.photoIndex],
                    in: frame.rect,
                    context: cgContext,
                    usesLandscapePresentationCrop: format.usesLandscapePhotoPresentation
                )
            }

            let photoBottom = Int(plan.photoFrames.map(\.rect.maxY).max() ?? CGFloat(y))
            if let galleryURL,
               let qrImage = try? GalleryQRCodeGenerator.makeQRCodeImage(for: galleryURL, pixelSize: plan.qrSize) {
                drawCompactGalleryFooter(
                    qrImage: qrImage,
                    date: date,
                    sessionIdentifier: sessionIdentifier,
                    photoBottom: photoBottom,
                    margin: margin,
                    width: width,
                    qrSize: plan.qrSize,
                    context: cgContext
                )
            } else {
                drawMetadataFooter(
                    date: date,
                    sessionIdentifier: sessionIdentifier,
                    photoBottom: photoBottom,
                    margin: margin,
                    width: width
                )
            }
        }

        guard let data = image.pngData(), image.size.width == CGFloat(width), image.size.height == CGFloat(height) else {
            throw ReceiptComposerError.renderFailed
        }

        debugLog("Composed \(format.rawValue) receipt \(sessionIdentifier). Dimensions: \(width)x\(height). Estimated length: \(String(format: "%.1f", Double(height) / 8.0)) mm.")

        return ComposedReceipt(
            imagePNGData: data,
            width: width,
            height: height,
            previewContentHeight: plan.previewContentHeight,
            sessionIdentifier: sessionIdentifier,
            createdAt: date,
            format: format
        )
    }

    nonisolated static func makeLayoutPlan(
        format: BoothFormat,
        includesGalleryQRCode: Bool = true
    ) throws -> ReceiptLayoutPlan {
        let width = BoothConfiguration.receiptWidth
        let margin = BoothConfiguration.receiptHorizontalMargin
        let fullPhotoWidth = width - (margin * 2)
        let top = 86
        let photoFrames: [ReceiptPhotoFrame]
        let groupFrame: CGRect?

        switch format {
        case .solo:
            let photoWidth = fullPhotoWidth
            let rect = centeredPortraitRect(y: top, width: photoWidth, in: width)
            photoFrames = [ReceiptPhotoFrame(photoIndex: 0, rect: rect)]
            groupFrame = nil
        case .duo:
            let photoWidth = fullPhotoWidth
            let first = centeredLandscapeRect(y: top, width: photoWidth, in: width)
            let second = centeredLandscapeRect(y: Int(first.maxY) + 10, width: photoWidth, in: width)
            photoFrames = [
                ReceiptPhotoFrame(photoIndex: 0, rect: first),
                ReceiptPhotoFrame(photoIndex: 1, rect: second)
            ]
            groupFrame = nil
        case .grid:
            let gap = 8
            let photoWidth = (fullPhotoWidth - gap) / 2
            let photoHeight = portraitHeight(for: photoWidth)
            let totalWidth = photoWidth * 2 + gap
            let leftX = (width - totalWidth) / 2
            let row2Y = top + photoHeight + gap
            photoFrames = [
                ReceiptPhotoFrame(photoIndex: 0, rect: CGRect(x: leftX, y: top, width: photoWidth, height: photoHeight)),
                ReceiptPhotoFrame(photoIndex: 1, rect: CGRect(x: leftX + photoWidth + gap, y: top, width: photoWidth, height: photoHeight)),
                ReceiptPhotoFrame(photoIndex: 2, rect: CGRect(x: leftX, y: row2Y, width: photoWidth, height: photoHeight)),
                ReceiptPhotoFrame(photoIndex: 3, rect: CGRect(x: leftX + photoWidth + gap, y: row2Y, width: photoWidth, height: photoHeight))
            ]
            groupFrame = nil
        case .strip:
            let photoWidth = fullPhotoWidth
            let photoHeight = landscapePresentationHeight(for: photoWidth)
            let gap = 10
            let x = (width - photoWidth) / 2
            var frames: [ReceiptPhotoFrame] = []
            var y = top
            for index in 0..<3 {
                let rect = CGRect(x: x, y: y, width: photoWidth, height: photoHeight)
                frames.append(ReceiptPhotoFrame(photoIndex: index, rect: rect))
                y = Int(rect.maxY) + gap
            }
            photoFrames = frames
            groupFrame = nil
        }

        let photoBottom = Int(photoFrames.map(\.rect.maxY).max() ?? CGFloat(top))
        let previewContentHeight = photoBottom + 12
        let footerHeight = includesGalleryQRCode ? compactGalleryFooterHeight(qrSize: receiptQRCodeSize) : metadataOnlyFooterHeight
        let height = photoBottom + footerHeight

        return ReceiptLayoutPlan(
            format: format,
            displayedPhotoIndexes: Array(0..<format.photoCount),
            photoFrames: photoFrames,
            groupFrame: groupFrame,
            width: width,
            height: height,
            previewContentHeight: previewContentHeight,
            qrSize: includesGalleryQRCode ? receiptQRCodeSize : 0
        )
    }

    nonisolated static func makePhotoSectionPreviewImage(from image: UIImage, previewContentHeight: Int) -> UIImage {
        let normalized = normalizedUpImage(from: image)
        guard normalized.size.width > 0,
              normalized.size.height > 0,
              previewContentHeight > 0,
              let cgImage = normalized.cgImage else {
            return normalized
        }

        let pixelHeight = min(max(1, previewContentHeight), cgImage.height)
        let cropRect = CGRect(x: 0, y: 0, width: cgImage.width, height: pixelHeight)
        guard let cropped = cgImage.cropping(to: cropRect) else {
            return normalized
        }

        return UIImage(cgImage: cropped, scale: 1, orientation: .up)
    }

    nonisolated private static func compactGalleryFooterHeight(qrSize: Int) -> Int {
        footerTopDividerPadding + footerContentTopPadding + qrSize + footerContentBottomPadding + footerBottomPadding
    }

    nonisolated private static var metadataOnlyFooterHeight: Int {
        10 + 20 + 18 + 24 + footerBottomPadding
    }

    nonisolated private static func drawCompactGalleryFooter(
        qrImage: UIImage,
        date: Date,
        sessionIdentifier: String,
        photoBottom: Int,
        margin: Int,
        width: Int,
        qrSize: Int,
        context: CGContext
    ) {
        let dividerY = photoBottom + footerTopDividerPadding
        drawDivider(y: dividerY, margin: margin, width: width)

        let rowTop = dividerY + footerContentTopPadding
        let qrX = margin
        context.interpolationQuality = .none
        qrImage.draw(in: CGRect(x: qrX, y: rowTop, width: qrSize, height: qrSize))

        let textX = qrX + qrSize + footerColumnGutter
        let textWidth = width - margin - textX
        var textY = rowTop + 22
        drawText("SCAN TO VIEW", x: textX, y: textY, font: .systemFont(ofSize: 20, weight: .bold), alignment: .left, width: textWidth)
        textY += 24
        drawText("& SAVE YOUR PHOTOS", x: textX, y: textY, font: .systemFont(ofSize: 17, weight: .semibold), alignment: .left, width: textWidth)
        textY += 32
        drawText(receiptDateFormatter.string(from: date).uppercased(), x: textX, y: textY, font: .monospacedDigitSystemFont(ofSize: 13, weight: .regular), alignment: .left, width: textWidth)
        textY += 18
        drawText(sessionIdentifier, x: textX, y: textY, font: .monospacedDigitSystemFont(ofSize: 12, weight: .regular), alignment: .left, width: textWidth)
        textY += 26
        drawText("@pocketpixels.ceb", x: textX, y: textY, font: .systemFont(ofSize: 17, weight: .semibold), alignment: .left, width: textWidth)

        let bottomDividerY = rowTop + qrSize + footerContentBottomPadding
        drawDivider(y: bottomDividerY, margin: margin, width: width)
    }

    nonisolated private static func drawMetadataFooter(
        date: Date,
        sessionIdentifier: String,
        photoBottom: Int,
        margin: Int,
        width: Int
    ) {
        var y = photoBottom + footerTopDividerPadding
        drawDivider(y: y, margin: margin, width: width)
        y += 10
        drawCentered(receiptDateFormatter.string(from: date).uppercased(), y: y, width: width, font: .monospacedDigitSystemFont(ofSize: 15, weight: .regular))
        y += 20
        drawCentered(sessionIdentifier, y: y, width: width, font: .monospacedDigitSystemFont(ofSize: 13, weight: .regular))
        y += 18
        drawCentered("@pocketpixels.ceb", y: y, width: width, font: .systemFont(ofSize: 19, weight: .semibold))
        y += 24
        drawDivider(y: y, margin: margin, width: width)
    }

    nonisolated private static func centeredPortraitRect(y: Int, width photoWidth: Int, in receiptWidth: Int) -> CGRect {
        CGRect(
            x: (receiptWidth - photoWidth) / 2,
            y: y,
            width: photoWidth,
            height: portraitHeight(for: photoWidth)
        )
    }

    nonisolated private static func centeredLandscapeRect(y: Int, width photoWidth: Int, in receiptWidth: Int) -> CGRect {
        CGRect(
            x: (receiptWidth - photoWidth) / 2,
            y: y,
            width: photoWidth,
            height: landscapePresentationHeight(for: photoWidth)
        )
    }

    nonisolated private static func portraitHeight(for width: Int) -> Int {
        width * 4 / 3
    }

    nonisolated private static func stripPresentationHeight(for width: Int) -> Int {
        landscapePresentationHeight(for: width)
    }

    nonisolated private static func landscapePresentationHeight(for width: Int) -> Int {
        width * Int(landscapePresentationCropAspectRatio.height) / Int(landscapePresentationCropAspectRatio.width)
    }

    nonisolated static func makeLandscapePresentationPhoto(from image: UIImage) -> UIImage {
        makeCroppedPresentationPhoto(from: image, aspectRatio: landscapePresentationCropAspectRatio)
    }

    nonisolated static func makeStripPresentationPhoto(from image: UIImage) -> UIImage {
        makeLandscapePresentationPhoto(from: image)
    }

    nonisolated private static func makeCroppedPresentationPhoto(from image: UIImage, aspectRatio: CGSize) -> UIImage {
        let normalized = normalizedUpImage(from: image)
        guard normalized.size.width > 0,
              normalized.size.height > 0,
              let cgImage = normalized.cgImage else {
            return normalized
        }

        let cropRect = centeredCropRect(
            fitting: aspectRatio,
            in: CGSize(width: cgImage.width, height: cgImage.height)
        )

        guard let cropped = cgImage.cropping(to: cropRect) else {
            return normalized
        }

        return UIImage(cgImage: cropped, scale: 1, orientation: .up)
    }

    nonisolated private static func drawPhoto(_ image: UIImage, in rect: CGRect, context: CGContext, usesLandscapePresentationCrop: Bool) {
        context.interpolationQuality = .high
        let displayImage = usesLandscapePresentationCrop ? makeLandscapePresentationPhoto(from: image) : image
        drawAspectFill(displayImage, in: rect, context: context)
        UIColor.black.setStroke()
        context.setLineWidth(2)
        context.stroke(rect.insetBy(dx: 1, dy: 1))
    }

    nonisolated private static func drawAspectFill(_ image: UIImage, in rect: CGRect, context: CGContext) {
        guard image.size.width > 0, image.size.height > 0 else {
            UIColor.white.setFill()
            context.fill(rect)
            return
        }

        context.saveGState()
        context.clip(to: rect)

        let scale = max(rect.width / image.size.width, rect.height / image.size.height)
        let drawSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let origin = CGPoint(x: rect.midX - drawSize.width / 2, y: rect.midY - drawSize.height / 2)
        image.draw(in: CGRect(origin: origin, size: drawSize))

        context.restoreGState()
    }

    nonisolated private static func normalizedUpImage(from image: UIImage) -> UIImage {
        if image.imageOrientation == .up, image.cgImage != nil {
            return image
        }

        let pixelSize = CGSize(
            width: max(1, floor(image.size.width * image.scale)),
            height: max(1, floor(image.size.height * image.scale))
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true

        let renderer = UIGraphicsImageRenderer(size: pixelSize, format: format)
        return renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: pixelSize))
            image.draw(in: CGRect(origin: .zero, size: pixelSize))
        }
    }

    nonisolated private static func centeredCropRect(fitting targetAspectRatio: CGSize, in sourceSize: CGSize) -> CGRect {
        guard sourceSize.width > 0,
              sourceSize.height > 0,
              targetAspectRatio.width > 0,
              targetAspectRatio.height > 0 else {
            return .zero
        }

        let targetRatio = targetAspectRatio.width / targetAspectRatio.height
        let sourceRatio = sourceSize.width / sourceSize.height
        let cropSize: CGSize

        if sourceRatio > targetRatio {
            let cropWidth = floor(sourceSize.height * targetRatio)
            cropSize = CGSize(width: cropWidth, height: sourceSize.height)
        } else {
            let cropHeight = floor(sourceSize.width / targetRatio)
            cropSize = CGSize(width: sourceSize.width, height: cropHeight)
        }

        return CGRect(
            x: floor((sourceSize.width - cropSize.width) / 2),
            y: floor((sourceSize.height - cropSize.height) / 2),
            width: cropSize.width,
            height: cropSize.height
        )
    }

    nonisolated private static func drawCentered(_ text: String, y: Int, width: Int, font: UIFont) {
        drawText(text, x: 0, y: y, font: font, alignment: .center, width: width)
    }

    nonisolated private static func drawText(_ text: String, x: Int, y: Int, font: UIFont, alignment: NSTextAlignment, width: Int) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor.black,
            .paragraphStyle: paragraph
        ]

        NSString(string: text).draw(
            in: CGRect(x: x, y: y, width: width, height: Int(font.lineHeight) + 8),
            withAttributes: attributes
        )
    }

    nonisolated private static func drawDivider(y: Int, margin: Int, width: Int) {
        let path = UIBezierPath()
        path.move(to: CGPoint(x: margin, y: y))
        path.addLine(to: CGPoint(x: width - margin, y: y))
        path.lineWidth = 1
        UIColor.black.setStroke()
        path.stroke()
    }

    nonisolated private static let identifierFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = sessionIdentifierTimeZone
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    nonisolated private static let receiptDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = sessionIdentifierTimeZone
        formatter.dateFormat = "MMM d, yyyy • h:mm a"
        return formatter
    }()
}

nonisolated private func debugLog(_ message: String) {
#if DEBUG
    print("[ReceiptComposer] \(message)")
#endif
}

private extension BoothFormat {
    var usesLandscapePhotoPresentation: Bool {
        self == .duo || self == .strip
    }
}
