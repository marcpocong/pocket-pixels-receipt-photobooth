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
    let photoQualityProfile: PocketPixelsThermalPhotoProfile

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
    nonisolated private static let footerTopDividerPadding = 16
    nonisolated private static let footerContentTopPadding = 10
    nonisolated private static let footerContentBottomPadding = 10
    nonisolated private static let footerBottomPadding = 14
    nonisolated private static let footerColumnGutter = 22
    nonisolated private static let footerHandleMonogramSize = 32
    nonisolated private static let footerHandleMonogramToTextGap = 10
    nonisolated private static let standardPhotoTop = 86

    nonisolated static func makeSessionIdentifier(date: Date = Date()) -> String {
        "PP-\(identifierFormatter.string(from: date))"
    }

    nonisolated static func compose(
        photos: [UIImage],
        sessionIdentifier: String,
        date: Date = Date(),
        galleryURL: URL? = nil,
        format: BoothFormat,
        eventProfile: EventProfile? = nil,
        photoQualityProfile: PocketPixelsThermalPhotoProfile = .customerPrintDefault
    ) throws -> ComposedReceipt {
        guard photos.count == format.photoCount else {
            throw ReceiptComposerError.missingPhotos(expected: format.photoCount, actual: photos.count)
        }

        let eventSnapshot = eventProfile?.activeReceiptSnapshot
        let plan = try makeLayoutPlan(format: format, includesGalleryQRCode: galleryURL != nil, eventProfile: eventSnapshot)
        let width = BoothConfiguration.receiptWidth
        let margin = BoothConfiguration.receiptHorizontalMargin
        let height = plan.height

        guard height <= BoothConfiguration.receiptMaximumHeight else {
            throw ReceiptComposerError.heightExceeded(height)
        }

        let preparedPhotos = try preparePhotos(
            photos,
            for: plan,
            profile: photoQualityProfile
        )

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
            if let eventSnapshot {
                drawEventBlock(eventSnapshot, startY: standardPhotoTop, margin: margin, width: width)
            }

            if let groupFrame = plan.groupFrame {
                UIColor.black.setStroke()
                cgContext.setLineWidth(2)
                cgContext.stroke(groupFrame.insetBy(dx: 1, dy: 1))
            }

            for frame in plan.photoFrames {
                drawPhoto(
                    preparedPhotos[frame.photoIndex].image,
                    in: frame.rect,
                    context: cgContext
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

#if DEBUG
        if let eventSnapshot {
            let eventBlockHeight = measureEventBlockHeight(for: eventSnapshot, width: width, margin: margin)
            debugLog("[EventReceipt] eventBlockHeight=\(eventBlockHeight) receiptHeight=\(height) estimatedLengthMM=\(String(format: "%.1f", Double(height) / 8.0))")
        }
#endif
        debugLog("Composed \(format.rawValue) receipt \(sessionIdentifier). Dimensions: \(width)x\(height). Estimated length: \(String(format: "%.1f", Double(height) / 8.0)) mm.")

        return ComposedReceipt(
            imagePNGData: data,
            width: width,
            height: height,
            previewContentHeight: plan.previewContentHeight,
            sessionIdentifier: sessionIdentifier,
            createdAt: date,
            format: format,
            photoQualityProfile: photoQualityProfile
        )
    }

    nonisolated static func makeLayoutPlan(
        format: BoothFormat,
        includesGalleryQRCode: Bool = true,
        eventProfile: EventProfile? = nil
    ) throws -> ReceiptLayoutPlan {
        let width = BoothConfiguration.receiptWidth
        let margin = BoothConfiguration.receiptHorizontalMargin
        let fullPhotoWidth = width - (margin * 2)
        let eventSnapshot = eventProfile?.activeReceiptSnapshot
        let top = eventSnapshot.map { eventBlockPhotoTop($0, startY: standardPhotoTop, margin: margin, width: width) } ?? standardPhotoTop
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

    nonisolated static func measureEventBlockHeight(
        for profile: EventProfile,
        width: Int = BoothConfiguration.receiptWidth,
        margin: Int = BoothConfiguration.receiptHorizontalMargin
    ) -> Int {
        guard let content = profile.receiptBlockContent else {
            return 0
        }

        let textWidth = eventBlockTextWidth(margin: margin, width: width)
        let titleFont = eventTitleFont(for: content.eventName)
        var height = 8

        height += measuredWrappedTextHeight(content.eyebrow, font: eventEyebrowFont, width: textWidth, tracking: 1.8)
        height += 3
        height += measuredWrappedTextHeight(content.eventName, font: titleFont, width: textWidth, lineSpacing: 1)

        if !content.subtitle.isEmpty {
            height += 5
            height += measuredWrappedTextHeight(content.subtitle, font: eventSubtitleFont, width: textWidth)
        }

        if !content.metadata.isEmpty {
            height += 4
            height += measuredWrappedTextHeight(content.metadata, font: eventMetadataFont, width: textWidth, tracking: 0.4)
        }

        if !content.message.isEmpty {
            height += 4
            height += measuredWrappedTextHeight(content.message, font: eventMessageFont, width: textWidth)
        }

        height += 9
        height += 12
        return height
    }

    nonisolated static func preparePhotos(
        _ photos: [UIImage],
        for plan: ReceiptLayoutPlan,
        profile: PocketPixelsThermalPhotoProfile = .customerPrintDefault
    ) throws -> [ThermalPreparedPhoto] {
        try photos.enumerated().map { index, photo in
            guard let frame = plan.photoFrames.first(where: { $0.photoIndex == index }) else {
                throw ReceiptComposerError.renderFailed
            }

            return try ThermalPhotoProcessor.prepare(
                photo,
                targetPixelSize: frame.rect.size,
                presentationMode: plan.format.photoPresentationMode,
                profile: profile
            )
        }
    }

    nonisolated private static func compactGalleryFooterHeight(qrSize: Int) -> Int {
        footerTopDividerPadding + footerContentTopPadding + qrSize + footerContentBottomPadding + footerBottomPadding
    }

    nonisolated private static var metadataOnlyFooterHeight: Int {
        10 + 20 + 18 + 24 + footerBottomPadding
    }

    nonisolated private static func eventBlockPhotoTop(
        _ profile: EventProfile,
        startY: Int,
        margin: Int,
        width: Int
    ) -> Int {
        startY + measureEventBlockHeight(for: profile, width: width, margin: margin)
    }

    nonisolated private static func drawEventBlock(
        _ profile: EventProfile,
        startY: Int,
        margin: Int,
        width: Int
    ) {
        guard let content = profile.receiptBlockContent else {
            return
        }

        var y = startY + 8
        let textX = eventBlockTextX(margin: margin)
        let textWidth = eventBlockTextWidth(margin: margin, width: width)
        let titleFont = eventTitleFont(for: content.eventName)

        y += drawCenteredWrapped(content.eyebrow, x: textX, y: y, width: textWidth, font: eventEyebrowFont, tracking: 1.8)
        y += 3
        y += drawCenteredWrapped(content.eventName, x: textX, y: y, width: textWidth, font: titleFont, lineSpacing: 1)

        if !content.subtitle.isEmpty {
            y += 5
            y += drawCenteredWrapped(content.subtitle, x: textX, y: y, width: textWidth, font: eventSubtitleFont)
        }

        if !content.metadata.isEmpty {
            y += 4
            y += drawCenteredWrapped(content.metadata, x: textX, y: y, width: textWidth, font: eventMetadataFont, tracking: 0.4)
        }

        if !content.message.isEmpty {
            y += 4
            y += drawCenteredWrapped(content.message, x: textX, y: y, width: textWidth, font: eventMessageFont)
        }

        y += 9
        drawDivider(y: y, margin: margin, width: width)
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

        let infoTextX = qrX + qrSize + footerColumnGutter
        let textWidth = width - margin - infoTextX
        let handle = "@pocketpixels.ceb"
        let scanFont = UIFont.systemFont(ofSize: 21, weight: .bold)
        let saveFont = UIFont.systemFont(ofSize: 16, weight: .semibold)
        let metadataFont = UIFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        let sessionFont = UIFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        let handleFont = UIFont.systemFont(ofSize: 16, weight: .semibold)
        let handleTextX = infoTextX + footerHandleMonogramSize + footerHandleMonogramToTextGap
        let handleTextWidth = width - margin - handleTextX

        var textY = rowTop + 22
        drawMeasuredText("SCAN TO VIEW", x: infoTextX, y: textY, font: scanFont, availableWidth: textWidth)
        textY += 25
        drawMeasuredText("& SAVE YOUR PHOTOS", x: infoTextX, y: textY, font: saveFont, availableWidth: textWidth)
        textY += 42
        drawMeasuredText(receiptDateFormatter.string(from: date).uppercased(), x: infoTextX, y: textY, font: metadataFont, availableWidth: textWidth)
        textY += 20
        drawMeasuredText(sessionIdentifier, x: infoTextX, y: textY, font: sessionFont, availableWidth: textWidth)
        textY += 30

        let handleRowY = textY
        let monogramY = handleRowY + Int(floor((handleFont.lineHeight - CGFloat(footerHandleMonogramSize)) / 2)) - 1
        drawFooterMonogram(in: CGRect(
            x: infoTextX,
            y: monogramY,
            width: footerHandleMonogramSize,
            height: footerHandleMonogramSize
        ))
        drawMeasuredText(handle, x: handleTextX, y: handleRowY, font: handleFont, availableWidth: handleTextWidth)
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

    nonisolated private static func drawPhoto(_ image: UIImage, in rect: CGRect, context: CGContext) {
        context.interpolationQuality = .high
        image.draw(in: rect)
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

    nonisolated private static func drawFooterMonogram(in rect: CGRect) {
        guard let monogram = UIImage(named: "PocketPixelsMonogram") else {
            return
        }

        let blackMonogram = trimmedToVisibleAlpha(monogram).withTintColor(.black, renderingMode: .alwaysOriginal)
        blackMonogram.draw(in: aspectFitRect(for: blackMonogram.size, in: rect))
    }

    nonisolated private static func trimmedToVisibleAlpha(_ image: UIImage) -> UIImage {
        guard let cgImage = image.cgImage,
              let alphaBounds = visibleAlphaBounds(in: cgImage),
              let cropped = cgImage.cropping(to: alphaBounds) else {
            return image
        }

        return UIImage(cgImage: cropped, scale: image.scale, orientation: .up)
    }

    nonisolated private static func visibleAlphaBounds(in image: CGImage) -> CGRect? {
        let width = image.width
        let height = image.height
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)

        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var minX = width
        var minY = height
        var maxX = -1
        var maxY = -1
        for y in 0..<height {
            let rowOffset = y * bytesPerRow
            for x in 0..<width {
                let alpha = pixels[rowOffset + (x * bytesPerPixel) + 3]
                if alpha > 0 {
                    minX = min(minX, x)
                    minY = min(minY, y)
                    maxX = max(maxX, x)
                    maxY = max(maxY, y)
                }
            }
        }

        guard maxX >= minX, maxY >= minY else {
            return nil
        }

        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    nonisolated private static func aspectFitRect(for sourceSize: CGSize, in targetRect: CGRect) -> CGRect {
        guard sourceSize.width > 0, sourceSize.height > 0 else {
            return targetRect
        }

        let scale = min(targetRect.width / sourceSize.width, targetRect.height / sourceSize.height)
        let drawSize = CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
        let origin = CGPoint(
            x: targetRect.midX - (drawSize.width / 2),
            y: targetRect.midY - (drawSize.height / 2)
        )

        return CGRect(origin: origin, size: drawSize)
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

    @discardableResult
    nonisolated private static func drawCenteredWrapped(
        _ text: String,
        x: Int,
        y: Int,
        width: Int,
        font: UIFont,
        tracking: CGFloat = 0,
        lineSpacing: CGFloat = 0
    ) -> Int {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = lineSpacing

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .kern: tracking,
            .foregroundColor: UIColor.black,
            .paragraphStyle: paragraph
        ]
        let height = measuredWrappedTextHeight(text, font: font, width: width, tracking: tracking, lineSpacing: lineSpacing)

        NSString(string: text).draw(
            in: CGRect(x: x, y: y, width: width, height: height + 2),
            withAttributes: attributes
        )

        return height
    }

    nonisolated private static func drawMeasuredText(_ text: String, x: Int, y: Int, font: UIFont, availableWidth: Int) {
        let measuredWidth = Int(ceil(measuredTextWidth(text, font: font))) + 6
        drawText(text, x: x, y: y, font: font, alignment: .left, width: min(measuredWidth, availableWidth))
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

    nonisolated private static func measuredTextWidth(_ text: String, font: UIFont) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        return NSString(string: text).boundingRect(
            with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes,
            context: nil
        ).width
    }

    nonisolated private static func measuredWrappedTextHeight(
        _ text: String,
        font: UIFont,
        width: Int,
        tracking: CGFloat = 0,
        lineSpacing: CGFloat = 0
    ) -> Int {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = lineSpacing

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .kern: tracking,
            .paragraphStyle: paragraph
        ]
        let rect = NSString(string: text).boundingRect(
            with: CGSize(width: CGFloat(width), height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes,
            context: nil
        )

        return max(Int(ceil(rect.height)), Int(ceil(font.lineHeight)))
    }

    nonisolated private static func eventBlockTextX(margin: Int) -> Int {
        margin + 16
    }

    nonisolated private static func eventBlockTextWidth(margin: Int, width: Int) -> Int {
        width - (eventBlockTextX(margin: margin) * 2)
    }

    nonisolated private static var eventEyebrowFont: UIFont {
        .monospacedSystemFont(ofSize: 13, weight: .semibold)
    }

    nonisolated private static var eventSubtitleFont: UIFont {
        .systemFont(ofSize: 15, weight: .semibold)
    }

    nonisolated private static var eventMetadataFont: UIFont {
        .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
    }

    nonisolated private static var eventMessageFont: UIFont {
        .systemFont(ofSize: 14, weight: .regular)
    }

    nonisolated private static func eventTitleFont(for title: String) -> UIFont {
        let count = title.count
        let size: CGFloat

        if count <= 22 {
            size = 28
        } else if count <= 36 {
            size = 25
        } else {
            size = 22
        }

        let base = UIFont.systemFont(ofSize: size, weight: .semibold)
        guard let serifDescriptor = base.fontDescriptor.withDesign(.serif) else {
            return base
        }

        return UIFont(descriptor: serifDescriptor, size: size)
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

    nonisolated private static let eventDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = sessionIdentifierTimeZone
        formatter.dateFormat = "MMM d, yyyy"
        return formatter
    }()
}

nonisolated private func debugLog(_ message: String) {
#if DEBUG
    print("[ReceiptComposer] \(message)")
#endif
}

private extension BoothFormat {
    nonisolated var usesLandscapePhotoPresentation: Bool {
        self == .duo || self == .strip
    }

    nonisolated var photoPresentationMode: ThermalPhotoPresentationMode {
        switch self {
        case .solo, .grid:
            .portrait
        case .duo, .strip:
            .landscape
        }
    }
}
