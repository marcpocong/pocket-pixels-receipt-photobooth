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

    nonisolated var estimatedLengthMillimeters: Double {
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

private struct ReceiptFooterLayout: Sendable {
    let top: Int
    let height: Int
    let dividerY: Int
    let mainRowTop: Int
    let mainRowHeight: Int
    let qrRect: CGRect
    let textColumnRect: CGRect
    let ctaY: Int
    let subCTAY: Int
    let metadataY: Int
    let sessionY: Int
    let brandRowY: Int
    let brandRowHeight: Int
    let monogramRect: CGRect
    let handleX: Int
    let handleY: Int
    let handleWidth: Int
    let brandRowWidth: Int
    let closingY: Int
    let bottomPadding: Int
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
    nonisolated static let receiptQRCodeSize = 196
    nonisolated static let landscapePresentationCropAspectRatio = CGSize(width: 4, height: 3)
    nonisolated static let landscapePresentationAspectRatio = landscapePresentationCropAspectRatio.width / landscapePresentationCropAspectRatio.height
    nonisolated static let stripPresentationCropAspectRatio = landscapePresentationCropAspectRatio
    nonisolated private static let receiptTopPadding = 14
    nonisolated private static let mastheadEstablishedBottomGap = 5
    nonisolated private static let mastheadWordmarkBottomGap = 3
    nonisolated private static let mastheadBottomGap = 12
    nonisolated private static let eventHeaderHorizontalInset = 28
    nonisolated private static let eventHeaderKickerBottomGap = 5
    nonisolated private static let eventHeaderTitleBottomGap = 5
    nonisolated private static let eventHeaderDetailGap = 4
    nonisolated private static let eventHeaderBottomPadding = 12
    nonisolated private static let eventHeaderPhotoGap = 12
    nonisolated private static let photoStackGap = 8
    nonisolated private static let footerTopDividerPadding = 10
    nonisolated private static let footerContentTopPadding = 8
    nonisolated private static let footerBrandTopPadding = 6
    nonisolated private static let footerBrandRowHeight = 26
    nonisolated private static let footerClosingTopPadding = 3
    nonisolated private static let footerClosingHeight = 16
    nonisolated private static let footerBottomPadding = 8
    nonisolated private static let footerColumnGutter = 20
    nonisolated private static let footerHandleMonogramSize = 24
    nonisolated private static let footerHandleMonogramToTextGap = 8
    nonisolated private static let footerTextTopInset = 0
    nonisolated private static let footerCTAToMetadataGap = 15
    nonisolated private static let footerMetadataToSessionGap = 5

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

            drawPocketPixelsMasthead(eventSnapshot: eventSnapshot, startY: receiptTopPadding, margin: margin, width: width)

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

            let photoBottom = Int(plan.photoFrames.map(\.rect.maxY).max() ?? 0)
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
        let headerHeight = measurePocketPixelsHeaderHeight(eventProfile: eventSnapshot, width: width, margin: margin)
        debugLog("[ReceiptHeader] headerHeight=\(headerHeight) event=\(eventSnapshot != nil) receiptHeight=\(height) estimatedLengthMM=\(String(format: "%.1f", Double(height) / 8.0))")
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
        let top = pocketPixelsHeaderPhotoTop(eventProfile: eventSnapshot, startY: receiptTopPadding, margin: margin, width: width)
        let verticalPhotoGap = photoStackGap
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
            let second = centeredLandscapeRect(y: Int(first.maxY) + verticalPhotoGap, width: photoWidth, in: width)
            photoFrames = [
                ReceiptPhotoFrame(photoIndex: 0, rect: first),
                ReceiptPhotoFrame(photoIndex: 1, rect: second)
            ]
            groupFrame = nil
        case .grid:
            let gap = photoStackGap
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
            let x = (width - photoWidth) / 2
            var frames: [ReceiptPhotoFrame] = []
            var y = top
            for index in 0..<3 {
                let rect = CGRect(x: x, y: y, width: photoWidth, height: photoHeight)
                frames.append(ReceiptPhotoFrame(photoIndex: index, rect: rect))
                y = Int(rect.maxY) + verticalPhotoGap
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

    nonisolated static func measurePocketPixelsHeaderHeight(
        eventProfile: EventProfile?,
        width: Int = BoothConfiguration.receiptWidth,
        margin: Int = BoothConfiguration.receiptHorizontalMargin
    ) -> Int {
        let content = eventProfile?.receiptBlockContent
        let textWidth = mastheadTextWidth(margin: margin, width: width)
        var height = 0

        height += Int(ceil(mastheadEstablishedFont.lineHeight))
        height += mastheadEstablishedBottomGap
        height += Int(ceil(mastheadWordmarkFont.lineHeight))
        height += mastheadWordmarkBottomGap
        height += Int(ceil(mastheadLabelFont.lineHeight))
        height += mastheadBottomGap

        if let content {
            let titleFont = eventTitleFont(for: content.eventName, width: textWidth)
            height += measuredWrappedTextHeight(content.eyebrow, font: eventEyebrowFont, width: textWidth, tracking: 1.8)
            height += eventHeaderKickerBottomGap
            height += measuredWrappedTextHeight(content.eventName, font: titleFont, width: textWidth, lineSpacing: 1, lineBreakMode: .byCharWrapping)
            height += eventHeaderTitleBottomGap

            if !content.subtitle.isEmpty {
                height += measuredWrappedTextHeight(content.subtitle, font: eventSubtitleFont, width: textWidth)
                height += eventHeaderDetailGap
            }

            if !content.metadata.isEmpty {
                height += measuredWrappedTextHeight(content.metadata, font: eventMetadataFont, width: textWidth, tracking: 0.4)
                height += eventHeaderDetailGap
            }

            if !content.message.isEmpty {
                height += measuredWrappedTextHeight(content.message.uppercased(), font: eventMessageFont, width: textWidth, tracking: 0.8)
            }

            height += eventHeaderBottomPadding
        }

        height += 1
        height += eventHeaderPhotoGap
        return height
    }

    nonisolated static func measureEventHeaderHeight(
        for profile: EventProfile,
        width: Int = BoothConfiguration.receiptWidth,
        margin: Int = BoothConfiguration.receiptHorizontalMargin
    ) -> Int {
        measurePocketPixelsHeaderHeight(eventProfile: profile, width: width, margin: margin)
    }

    nonisolated static func measureEventBlockHeight(
        for profile: EventProfile,
        width: Int = BoothConfiguration.receiptWidth,
        margin: Int = BoothConfiguration.receiptHorizontalMargin
    ) -> Int {
        measureEventHeaderHeight(for: profile, width: width, margin: margin)
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

#if DEBUG
    nonisolated static func runEventHeaderDebugSelfChecks() throws {
        let eventDate = Date(timeIntervalSince1970: 1_788_688_860)
        let eventProfile = EventProfile(
            isEnabled: true,
            eventName: "CEBU CITY LAUNCH NIGHT",
            subtitle: "EVENT MODE PREVIEW",
            includeEventDate: true,
            eventDate: eventDate,
            location: "CEBU CITY",
            shortMessage: "THANKS FOR CELEBRATING"
        )

        let standardPlan = try makeLayoutPlan(format: .duo, includesGalleryQRCode: true, eventProfile: nil)
        let eventPlan = try makeLayoutPlan(format: .duo, includesGalleryQRCode: true, eventProfile: eventProfile)
        guard Int(standardPlan.photoFrames.first?.rect.minY ?? 0) > 120,
              Int(eventPlan.photoFrames.first?.rect.minY ?? 0) > Int(standardPlan.photoFrames.first?.rect.minY ?? 0),
              eventProfile.receiptBlockContent != nil else {
            throw debugSelfCheckFailure("Event and standard header branch selection failed.")
        }

        let textWidth = mastheadTextWidth(margin: BoothConfiguration.receiptHorizontalMargin, width: BoothConfiguration.receiptWidth)
        let wordmarkBounds = measuredTextBounds("Pocket Pixels", font: mastheadWordmarkFont)
        let labelBounds = measuredTextBounds("RECEIPT PHOTOBOOTH", font: mastheadLabelFont, tracking: 4.0)
        let establishedBounds = measuredTextBounds("EST. 2026", font: mastheadEstablishedFont, tracking: 1.4)

        guard wordmarkBounds.width >= CGFloat(textWidth) * 0.70,
              wordmarkBounds.width <= CGFloat(textWidth) * 0.82,
              labelBounds.width >= CGFloat(textWidth) * 0.45,
              labelBounds.width <= CGFloat(textWidth) * 0.65,
              establishedBounds.height >= 13,
              establishedBounds.height <= 20 else {
            throw debugSelfCheckFailure("Event masthead typography proportions drifted.")
        }

        let footerLayout = makeCompactGalleryFooterLayout(
            photoBottom: 900,
            margin: BoothConfiguration.receiptHorizontalMargin,
            width: BoothConfiguration.receiptWidth,
            qrSize: receiptQRCodeSize
        )
        let ctaWidth = measuredTextWidth("SCAN TO VIEW", font: footerCTAFont)
        let subCTAWidth = measuredTextWidth("& SAVE YOUR PHOTOS", font: footerSubCTAFont)
        let metadataWidth = measuredTextWidth("SEP 7, 2026 • 8:30 AM", font: footerMetadataFont)
        let sessionWidth = measuredTextWidth("PP-20260907-083012", font: footerSessionFont)

        guard footerLayout.height == compactGalleryFooterHeight(qrSize: receiptQRCodeSize),
              footerLayout.qrRect.minX >= CGFloat(BoothConfiguration.receiptHorizontalMargin),
              footerLayout.qrRect.maxX < footerLayout.textColumnRect.minX,
              footerLayout.textColumnRect.maxX <= CGFloat(BoothConfiguration.receiptWidth - BoothConfiguration.receiptHorizontalMargin),
              ctaWidth <= footerLayout.textColumnRect.width,
              subCTAWidth <= footerLayout.textColumnRect.width,
              metadataWidth <= footerLayout.textColumnRect.width,
              sessionWidth <= footerLayout.textColumnRect.width,
              footerLayout.brandRowWidth < BoothConfiguration.receiptWidth,
              footerLayout.bottomPadding > 0 else {
            throw debugSelfCheckFailure("Shared receipt footer layout drifted outside the receipt grid.")
        }
    }
#endif

    nonisolated private static func compactGalleryFooterHeight(qrSize: Int) -> Int {
        makeCompactGalleryFooterLayout(
            photoBottom: 0,
            margin: BoothConfiguration.receiptHorizontalMargin,
            width: BoothConfiguration.receiptWidth,
            qrSize: qrSize
        ).height
    }

    nonisolated private static var metadataOnlyFooterHeight: Int {
        10 + 20 + 18 + 24 + footerBottomPadding
    }

    nonisolated private static func pocketPixelsHeaderPhotoTop(
        eventProfile: EventProfile?,
        startY: Int,
        margin: Int,
        width: Int
    ) -> Int {
        startY + measurePocketPixelsHeaderHeight(eventProfile: eventProfile, width: width, margin: margin)
    }

    nonisolated private static func drawPocketPixelsMasthead(
        eventSnapshot: EventProfile?,
        startY: Int,
        margin: Int,
        width: Int
    ) {
        let content = eventSnapshot?.receiptBlockContent
        var y = startY
        let textX = mastheadTextX(margin: margin)
        let textWidth = mastheadTextWidth(margin: margin, width: width)

        y += drawCenteredWrapped("EST. 2026", x: textX, y: y, width: textWidth, font: mastheadEstablishedFont, tracking: 1.4)
        y += mastheadEstablishedBottomGap
        y += drawCenteredWrapped("Pocket Pixels", x: textX, y: y, width: textWidth, font: mastheadWordmarkFont)
        y += mastheadWordmarkBottomGap
        y += drawCenteredWrapped("RECEIPT PHOTOBOOTH", x: textX, y: y, width: textWidth, font: mastheadLabelFont, tracking: 4.0)
        y += mastheadBottomGap

        if let content {
            let titleFont = eventTitleFont(for: content.eventName, width: textWidth)
            y += drawCenteredWrapped(content.eyebrow, x: textX, y: y, width: textWidth, font: eventEyebrowFont, tracking: 1.8)
            y += eventHeaderKickerBottomGap
            y += drawCenteredWrapped(content.eventName, x: textX, y: y, width: textWidth, font: titleFont, lineSpacing: 1, lineBreakMode: .byCharWrapping)
            y += eventHeaderTitleBottomGap

            if !content.subtitle.isEmpty {
                y += drawCenteredWrapped(content.subtitle, x: textX, y: y, width: textWidth, font: eventSubtitleFont)
                y += eventHeaderDetailGap
            }

            if !content.metadata.isEmpty {
                y += drawCenteredWrapped(content.metadata, x: textX, y: y, width: textWidth, font: eventMetadataFont, tracking: 0.4)
                y += eventHeaderDetailGap
            }

            if !content.message.isEmpty {
                y += drawCenteredWrapped(content.message.uppercased(), x: textX, y: y, width: textWidth, font: eventMessageFont, tracking: 0.8)
            }

            y += eventHeaderBottomPadding
        }

        drawDivider(y: y, margin: margin, width: width)
    }

    nonisolated private static func makeCompactGalleryFooterLayout(
        photoBottom: Int,
        margin: Int,
        width: Int,
        qrSize: Int
    ) -> ReceiptFooterLayout {
        let dividerY = photoBottom + footerTopDividerPadding
        let mainRowTop = dividerY + 1 + footerContentTopPadding
        let qrRect = CGRect(x: margin, y: mainRowTop, width: qrSize, height: qrSize)
        let textColumnX = margin + qrSize + footerColumnGutter
        let textColumnWidth = max(1, width - margin - textColumnX)
        let textColumnRect = CGRect(x: textColumnX, y: mainRowTop, width: textColumnWidth, height: qrSize)

        let ctaY = mainRowTop + footerTextTopInset
        let subCTAY = ctaY + Int(ceil(footerCTAFont.lineHeight)) + 1
        let naturalMetadataY = subCTAY + Int(ceil(footerSubCTAFont.lineHeight)) + footerCTAToMetadataGap
        let lowerMetadataY = mainRowTop + Int(round(CGFloat(qrSize) * 0.54))
        let metadataY = max(naturalMetadataY, lowerMetadataY)
        let sessionY = metadataY + Int(ceil(footerMetadataFont.lineHeight)) + footerMetadataToSessionGap

        let brandRowY = mainRowTop + qrSize + footerBrandTopPadding
        let handleWidth = Int(ceil(measuredTextWidth("@pocketpixels.ceb", font: footerHandleFont))) + 6
        let brandRowWidth = footerHandleMonogramSize + footerHandleMonogramToTextGap + handleWidth
        let brandRowX = (width - brandRowWidth) / 2
        let handleY = brandRowY + Int(floor((CGFloat(footerHandleMonogramSize) - footerHandleFont.lineHeight) / 2)) - 1
        let monogramRect = CGRect(
            x: brandRowX,
            y: brandRowY,
            width: footerHandleMonogramSize,
            height: footerHandleMonogramSize
        )
        let closingY = brandRowY + footerBrandRowHeight + footerClosingTopPadding
        let footerBottom = closingY + footerClosingHeight + footerBottomPadding

        return ReceiptFooterLayout(
            top: photoBottom,
            height: footerBottom - photoBottom,
            dividerY: dividerY,
            mainRowTop: mainRowTop,
            mainRowHeight: qrSize,
            qrRect: qrRect,
            textColumnRect: textColumnRect,
            ctaY: ctaY,
            subCTAY: subCTAY,
            metadataY: metadataY,
            sessionY: sessionY,
            brandRowY: brandRowY,
            brandRowHeight: footerBrandRowHeight,
            monogramRect: monogramRect,
            handleX: brandRowX + footerHandleMonogramSize + footerHandleMonogramToTextGap,
            handleY: handleY,
            handleWidth: handleWidth,
            brandRowWidth: brandRowWidth,
            closingY: closingY,
            bottomPadding: footerBottomPadding
        )
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
        let layout = makeCompactGalleryFooterLayout(photoBottom: photoBottom, margin: margin, width: width, qrSize: qrSize)
        drawDivider(y: layout.dividerY, margin: margin, width: width)

        context.interpolationQuality = .none
        qrImage.draw(in: layout.qrRect)
        drawFooterColumnDivider(for: layout)

        drawMeasuredText("SCAN TO VIEW", x: Int(layout.textColumnRect.minX), y: layout.ctaY, font: footerCTAFont, availableWidth: Int(layout.textColumnRect.width))
        drawMeasuredText("& SAVE YOUR PHOTOS", x: Int(layout.textColumnRect.minX), y: layout.subCTAY, font: footerSubCTAFont, availableWidth: Int(layout.textColumnRect.width))
        drawMeasuredText(receiptDateFormatter.string(from: date).uppercased(), x: Int(layout.textColumnRect.minX), y: layout.metadataY, font: footerMetadataFont, availableWidth: Int(layout.textColumnRect.width))
        drawMeasuredText(sessionIdentifier, x: Int(layout.textColumnRect.minX), y: layout.sessionY, font: footerSessionFont, availableWidth: Int(layout.textColumnRect.width))

        drawBrandClosing(layout: layout)
    }

    nonisolated private static func drawFooterColumnDivider(for layout: ReceiptFooterLayout) {
        let x = floor((layout.qrRect.maxX + layout.textColumnRect.minX) / 2)
        let path = UIBezierPath()
        path.move(to: CGPoint(x: x, y: CGFloat(layout.mainRowTop + 10)))
        path.addLine(to: CGPoint(x: x, y: CGFloat(layout.mainRowTop + layout.mainRowHeight - 10)))
        path.lineWidth = 1
        UIColor.black.setStroke()
        path.stroke()
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

    nonisolated private static func drawBrandClosing(layout: ReceiptFooterLayout) {
        let handle = "@pocketpixels.ceb"
        drawFooterMonogram(in: layout.monogramRect)
        drawMeasuredText(
            handle,
            x: layout.handleX,
            y: layout.handleY,
            font: footerHandleFont,
            availableWidth: layout.handleWidth
        )
        drawCentered("— THANK YOU —", y: layout.closingY, width: BoothConfiguration.receiptWidth, font: footerClosingFont)
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
        lineSpacing: CGFloat = 0,
        lineBreakMode: NSLineBreakMode = .byWordWrapping
    ) -> Int {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = lineBreakMode
        paragraph.lineSpacing = lineSpacing

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .kern: tracking,
            .foregroundColor: UIColor.black,
            .paragraphStyle: paragraph
        ]
        let height = measuredWrappedTextHeight(text, font: font, width: width, tracking: tracking, lineSpacing: lineSpacing, lineBreakMode: lineBreakMode)

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

    nonisolated private static func measuredTextBounds(_ text: String, font: UIFont, tracking: CGFloat = 0) -> CGRect {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .kern: tracking
        ]
        return NSString(string: text).boundingRect(
            with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes,
            context: nil
        )
    }

    nonisolated private static func measuredWrappedTextHeight(
        _ text: String,
        font: UIFont,
        width: Int,
        tracking: CGFloat = 0,
        lineSpacing: CGFloat = 0,
        lineBreakMode: NSLineBreakMode = .byWordWrapping
    ) -> Int {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = lineBreakMode
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

    nonisolated private static func mastheadTextX(margin: Int) -> Int {
        margin + eventHeaderHorizontalInset
    }

    nonisolated private static func mastheadTextWidth(margin: Int, width: Int) -> Int {
        width - (mastheadTextX(margin: margin) * 2)
    }

    nonisolated private static var mastheadEstablishedFont: UIFont {
        .monospacedSystemFont(ofSize: 11, weight: .medium)
    }

    nonisolated private static var mastheadWordmarkFont: UIFont {
        let size: CGFloat = 60
        let base = UIFont.systemFont(ofSize: size, weight: .semibold)
        guard let serifDescriptor = base.fontDescriptor.withDesign(.serif) else {
            return base
        }

        return UIFont(descriptor: serifDescriptor, size: size)
    }

    nonisolated private static var mastheadLabelFont: UIFont {
        .systemFont(ofSize: 17, weight: .semibold)
    }

    nonisolated private static var eventEyebrowFont: UIFont {
        .monospacedSystemFont(ofSize: 11, weight: .semibold)
    }

    nonisolated private static var eventSubtitleFont: UIFont {
        .systemFont(ofSize: 13, weight: .semibold)
    }

    nonisolated private static var eventMetadataFont: UIFont {
        .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
    }

    nonisolated private static var eventMessageFont: UIFont {
        .systemFont(ofSize: 12, weight: .semibold)
    }

    nonisolated private static var footerCTAFont: UIFont {
        .systemFont(ofSize: 30, weight: .bold)
    }

    nonisolated private static var footerSubCTAFont: UIFont {
        .systemFont(ofSize: 20, weight: .semibold)
    }

    nonisolated private static var footerMetadataFont: UIFont {
        .monospacedDigitSystemFont(ofSize: 15, weight: .medium)
    }

    nonisolated private static var footerSessionFont: UIFont {
        .monospacedDigitSystemFont(ofSize: 14, weight: .medium)
    }

    nonisolated private static var footerHandleFont: UIFont {
        .systemFont(ofSize: 18, weight: .semibold)
    }

    nonisolated private static var footerClosingFont: UIFont {
        .monospacedSystemFont(ofSize: 13, weight: .semibold)
    }

    nonisolated private static func eventTitleFont(for title: String, width: Int) -> UIFont {
        for size in [22, 20, 18] as [CGFloat] {
            let font = UIFont.systemFont(ofSize: size, weight: .bold)
            let height = measuredWrappedTextHeight(title, font: font, width: width, lineSpacing: 1, lineBreakMode: .byCharWrapping)
            if height <= Int(ceil(font.lineHeight * 2.35)) {
                return font
            }
        }

        return .systemFont(ofSize: 17, weight: .bold)
    }

    nonisolated private static func drawRule(fromX: Int, toX: Int, y: Int) {
        guard toX - fromX >= 10 else {
            return
        }

        let path = UIBezierPath()
        path.move(to: CGPoint(x: fromX, y: y))
        path.addLine(to: CGPoint(x: toX, y: y))
        path.lineWidth = 1
        UIColor.black.setStroke()
        path.stroke()
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

#if DEBUG
nonisolated private func debugSelfCheckFailure(_ message: String) -> NSError {
    NSError(
        domain: "ReceiptComposerDebugSelfChecks",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: message]
    )
}
#endif

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
