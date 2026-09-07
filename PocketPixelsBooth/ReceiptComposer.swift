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
    let contentLeft: Int
    let contentRight: Int
    let mainGroupX: Int
    let mainGroupWidth: Int
    let horizontalOpticalOffset: Int
    let qrRect: CGRect
    let textColumnRect: CGRect
    let rightStackMeasuredWidth: Int
    let rightStackEffectiveWidth: Int
    let ctaFrame: CGRect
    let subCTAFrame: CGRect
    let metadataFrame: CGRect
    let sessionFrame: CGRect
    let rightStackBottom: Int
    let mainRowBottom: Int
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

private struct ReceiptFooterMetrics: Sendable {
    let qrModuleScale: Int
    let qrSize: Int
    let gutter: Int
    let mainGroupHorizontalOpticalOffset: Int
    let ctaFontSize: CGFloat
    let ctaTracking: CGFloat
    let subCTAFontSize: CGFloat
    let subCTATracking: CGFloat
    let ctaLineGap: Int
    let ctaToMetadataGap: Int
    let metadataToSessionGap: Int
    let rightStackOpticalOffset: Int
    let brandTopPadding: Int
    let closingTopPadding: Int
    let bottomPadding: Int

    nonisolated static let production = ReceiptFooterMetrics(
        qrModuleScale: 3,
        qrSize: ReceiptComposer.receiptQRCodeSize,
        gutter: 24,
        mainGroupHorizontalOpticalOffset: 0,
        ctaFontSize: 34,
        ctaTracking: 3.4,
        subCTAFontSize: 22.5,
        subCTATracking: 2.0,
        ctaLineGap: 1,
        ctaToMetadataGap: 12,
        metadataToSessionGap: 4,
        rightStackOpticalOffset: 0,
        brandTopPadding: 6,
        closingTopPadding: 3,
        bottomPadding: 8
    )
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
    nonisolated static let receiptQRCodeSize = 177
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
    nonisolated private static let footerBrandRowHeight = 26
    nonisolated private static let footerClosingHeight = 16
    nonisolated private static let footerHandleMonogramSize = 24
    nonisolated private static let footerHandleMonogramToTextGap = 8
    nonisolated private static let footerBottomPadding = 8

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
            metrics: .production
        )
        let ctaFont = footerCTAFont(size: ReceiptFooterMetrics.production.ctaFontSize)
        let subCTAFont = footerSubCTAFont(size: ReceiptFooterMetrics.production.subCTAFontSize)
        let ctaWidth = measuredTextWidth("SCAN TO VIEW", font: ctaFont, tracking: ReceiptFooterMetrics.production.ctaTracking)
        let subCTAWidth = measuredTextWidth("& SAVE YOUR PHOTOS", font: subCTAFont, tracking: ReceiptFooterMetrics.production.subCTATracking)
        let metadataWidth = measuredTextWidth("SEP 7, 2026 • 8:30 AM", font: footerMetadataFont)
        let sessionWidth = measuredTextWidth("PP-20260907-083012", font: footerSessionFont)
        let expectedMetadataY = Int(ceil(footerLayout.subCTAFrame.maxY)) + ReceiptFooterMetrics.production.ctaToMetadataGap
        let largestGap = largestRightColumnGap(in: footerLayout)
        let ctaWidthUsage = footerLayout.ctaFrame.width / footerLayout.textColumnRect.width
        let subCTAWidthUsage = footerLayout.subCTAFrame.width / footerLayout.textColumnRect.width

        guard footerLayout.height == compactGalleryFooterHeight(qrSize: receiptQRCodeSize),
              Int(footerLayout.qrRect.minX) == BoothConfiguration.receiptHorizontalMargin,
              footerLayout.qrRect.maxX < footerLayout.textColumnRect.minX,
              Int(footerLayout.textColumnRect.maxX) == BoothConfiguration.receiptWidth - BoothConfiguration.receiptHorizontalMargin,
              footerLayout.mainGroupX == footerLayout.contentLeft,
              footerLayout.mainGroupWidth == footerLayout.contentRight - footerLayout.contentLeft,
              ctaWidthUsage >= 0.80,
              ctaWidthUsage <= 0.92,
              subCTAWidthUsage >= 0.78,
              subCTAWidthUsage <= 0.92,
              ctaWidth <= footerLayout.textColumnRect.width,
              subCTAWidth <= footerLayout.textColumnRect.width,
              metadataWidth <= footerLayout.textColumnRect.width,
              sessionWidth <= footerLayout.textColumnRect.width,
              Int(footerLayout.metadataFrame.minY) == expectedMetadataY,
              largestGap <= 16,
              abs(rightStackTopPadding(in: footerLayout) - rightStackBottomPadding(in: footerLayout)) <= 1,
              footerLayout.mainRowBottom == max(Int(ceil(footerLayout.qrRect.maxY)), footerLayout.rightStackBottom),
              footerLayout.brandRowY == footerLayout.mainRowBottom + ReceiptFooterMetrics.production.brandTopPadding,
              footerLayout.brandRowWidth < BoothConfiguration.receiptWidth,
              footerLayout.bottomPadding > 0 else {
            throw debugSelfCheckFailure("Shared receipt footer layout drifted outside the receipt grid.")
        }

        for format in BoothFormat.allCases {
            let standardPlan = try makeLayoutPlan(format: format, includesGalleryQRCode: true, eventProfile: nil)
            let eventPlan = try makeLayoutPlan(
                format: format,
                includesGalleryQRCode: true,
                eventProfile: EventProfile(
                    isEnabled: true,
                    eventName: "CEBU CITY LAUNCH NIGHT",
                    subtitle: "EVENT MODE PREVIEW",
                    includeEventDate: true,
                    eventDate: eventDate,
                    location: "CEBU CITY",
                    shortMessage: "THANKS FOR CELEBRATING"
                )
            )
            guard standardPlan.width == BoothConfiguration.receiptWidth,
                  eventPlan.width == BoothConfiguration.receiptWidth,
                  standardPlan.height <= BoothConfiguration.receiptMaximumHeight,
                  eventPlan.height <= BoothConfiguration.receiptMaximumHeight,
                  standardPlan.qrSize == receiptQRCodeSize,
                  eventPlan.qrSize == receiptQRCodeSize else {
                throw debugSelfCheckFailure("Shared receipt footer height drifted outside supported formats.")
            }
        }
    }

    nonisolated static func renderFooterOverhaulDebugArtifacts() throws {
        try renderFooterOverhaulFooterDebugArtifacts()
        try renderFooterOverhaulReceiptDebugArtifacts()
    }

    nonisolated static func renderFooterOverhaulFooterDebugArtifacts() throws {
        let outputDirectory = URL(
            fileURLWithPath: "/Users/marc/Desktop/PocketPixelsBooth/BuildArtifacts/FooterOverhaul",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let token = String(repeating: "a", count: 64)
        let galleryBaseURL = URL(string: CustomerGalleryConfiguration.placeholder)!
        let galleryURL = try GalleryURLBuilder.makeGalleryURL(customerGalleryBaseURL: galleryBaseURL, galleryToken: token)
        let date = makeDebugReceiptDate()
        let sessionIdentifier = "PP-20260907-091754"
        let exactScale3 = try GalleryQRCodeGenerator.moduleAlignedPixelSize(for: galleryURL, moduleScale: 3)
        let exactScale4 = try GalleryQRCodeGenerator.moduleAlignedPixelSize(for: galleryURL, moduleScale: 4)

        let compactMetrics = ReceiptFooterMetrics(
            qrModuleScale: 3,
            qrSize: exactScale3,
            gutter: 24,
            mainGroupHorizontalOpticalOffset: 0,
            ctaFontSize: 32,
            ctaTracking: 2.0,
            subCTAFontSize: 21.5,
            subCTATracking: 1.2,
            ctaLineGap: 1,
            ctaToMetadataGap: 12,
            metadataToSessionGap: 4,
            rightStackOpticalOffset: 0,
            brandTopPadding: 6,
            closingTopPadding: 3,
            bottomPadding: 8
        )
        let balancedMetrics = ReceiptFooterMetrics.production
        let roomyMetrics = ReceiptFooterMetrics(
            qrModuleScale: 3,
            qrSize: exactScale3,
            gutter: 24,
            mainGroupHorizontalOpticalOffset: 0,
            ctaFontSize: 34.5,
            ctaTracking: 4.0,
            subCTAFontSize: 23,
            subCTATracking: 2.5,
            ctaLineGap: 1,
            ctaToMetadataGap: 12,
            metadataToSessionGap: 4,
            rightStackOpticalOffset: 0,
            brandTopPadding: 6,
            closingTopPadding: 3,
            bottomPadding: 8
        )

        if let current = UIImage(contentsOfFile: "/Users/marc/Downloads/receipt-color.jpg"),
           let cgImage = current.cgImage {
            let cropHeight = 274
            let cropY = max(0, cgImage.height - cropHeight)
            if let cropped = cgImage.cropping(to: CGRect(x: 0, y: cropY, width: cgImage.width, height: cropHeight)) {
                try writeDebugImage(UIImage(cgImage: cropped, scale: 1, orientation: .up), named: "footer_current.png", to: outputDirectory)
            }
        }

        let compact = try renderDebugFooter(metrics: compactMetrics, date: date, sessionIdentifier: sessionIdentifier, galleryURL: galleryURL)
        let balanced = try renderDebugFooter(metrics: balancedMetrics, date: date, sessionIdentifier: sessionIdentifier, galleryURL: galleryURL)
        let roomy = try renderDebugFooter(metrics: roomyMetrics, date: date, sessionIdentifier: sessionIdentifier, galleryURL: galleryURL)
        let edgeCurrent = try renderEdgeCurrentDebugFooter(date: date, sessionIdentifier: sessionIdentifier, galleryURL: galleryURL)
        let horizontalBefore = try renderHorizontalBeforeDebugFooter(date: date, sessionIdentifier: sessionIdentifier, galleryURL: galleryURL)
        try writeDebugImage(edgeCurrent.image, named: "footer_edge_current.png", to: outputDirectory)
        try writeDebugImage(horizontalBefore.image, named: "footer_horizontal_before.png", to: outputDirectory)
        try writeDebugImage(compact.image, named: "footer_candidate_compact.png", to: outputDirectory)
        try writeDebugImage(compact.image, named: "footer_edge_conservative.png", to: outputDirectory)
        try writeDebugImage(balanced.image, named: "footer_candidate_balanced.png", to: outputDirectory)
        try writeDebugImage(balanced.image, named: "footer_edge_balanced.png", to: outputDirectory)
        try writeDebugImage(roomy.image, named: "footer_candidate_roomy.png", to: outputDirectory)
        try writeDebugImage(roomy.image, named: "footer_edge_bold.png", to: outputDirectory)
        try writeDebugImage(balanced.image, named: "footer_final.png", to: outputDirectory)
        try writeDebugImage(balanced.image, named: "footer_vertical_centered.png", to: outputDirectory)
        try writeDebugImage(balanced.image, named: "footer_horizontal_after.png", to: outputDirectory)
        try writeDebugImage(balanced.image, named: "footer_edge_selected.png", to: outputDirectory)

        let rasterizedFooter = try ThermalImageRasterizer.rasterize(balanced.image, purpose: .completeReceipt)
        if let oneBitFooter = UIImage(data: rasterizedFooter.previewPNGData) {
            try writeDebugImage(oneBitFooter, named: "footer_final_1bit.png", to: outputDirectory)
            try writeDebugImage(oneBitFooter, named: "footer_vertical_centered_1bit.png", to: outputDirectory)
            try writeDebugImage(oneBitFooter, named: "footer_horizontal_after_1bit.png", to: outputDirectory)
            try writeDebugImage(oneBitFooter, named: "footer_edge_selected_1bit.png", to: outputDirectory)
        }

        if let currentFooter = UIImage(contentsOfFile: outputDirectory.appendingPathComponent("footer_current.png").path) {
            let beforeAfter = makeBeforeAfterDebugImage(before: currentFooter, after: balanced.image)
            try writeDebugImage(beforeAfter, named: "footer_before_after_final.png", to: outputDirectory)
        }
        let edgeBeforeAfter = makeBeforeAfterDebugImage(before: edgeCurrent.image, after: balanced.image)
        try writeDebugImage(edgeBeforeAfter, named: "footer_edge_before_after.png", to: outputDirectory)

        printDebugLayout("conservative", compact.layout)
        printDebugLayout("balanced", balanced.layout)
        printDebugLayout("bold", roomy.layout)
        printDebugLayout("edgeCurrent", edgeCurrent.layout)
        printDebugLayout("horizontalBefore", horizontalBefore.layout)
        for size in [receiptQRCodeSize, 196, exactScale4] {
            let metrics = try GalleryQRCodeGenerator.makeRenderMetrics(for: galleryURL, pixelSize: size)
            print("QRMETRIC size=\(size) matrix=\(metrics.matrixModules) quiet=\(metrics.quietZoneModules) scale=\(metrics.moduleScale) renderedTotal=\(metrics.renderedTotalPixelSize) renderedMatrix=\(metrics.renderedMatrixPixelSize)")
        }
    }

    nonisolated static func renderFooterOverhaulReceiptDebugArtifacts() throws {
        let outputDirectory = URL(
            fileURLWithPath: "/Users/marc/Desktop/PocketPixelsBooth/BuildArtifacts/FooterOverhaul",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let token = String(repeating: "a", count: 64)
        let galleryBaseURL = URL(string: CustomerGalleryConfiguration.placeholder)!
        let galleryURL = try GalleryURLBuilder.makeGalleryURL(customerGalleryBaseURL: galleryBaseURL, galleryToken: token)
        let date = makeDebugReceiptDate()
        let sessionIdentifier = "PP-20260907-091754"
        let eventProfile = EventProfile(
            isEnabled: true,
            eventName: "CEBU CITY LAUNCH NIGHT",
            subtitle: "EVENT MODE PREVIEW",
            includeEventDate: true,
            eventDate: date,
            location: "CEBU CITY",
            shortMessage: "THANKS FOR CELEBRATING"
        )
        let photos = makeDebugReceiptPhotos()
        let standardSolo = try compose(photos: Array(photos.prefix(1)), sessionIdentifier: sessionIdentifier, date: date, galleryURL: galleryURL, format: .solo)
        let standardDuo = try compose(photos: Array(photos.prefix(2)), sessionIdentifier: sessionIdentifier, date: date, galleryURL: galleryURL, format: .duo)
        let eventSolo = try compose(photos: Array(photos.prefix(1)), sessionIdentifier: sessionIdentifier, date: date, galleryURL: galleryURL, format: .solo, eventProfile: eventProfile)
        let eventGrid = try compose(photos: Array(photos.prefix(4)), sessionIdentifier: sessionIdentifier, date: date, galleryURL: galleryURL, format: .grid, eventProfile: eventProfile)
        try writeDebugReceipt(standardSolo, named: "standard_solo_footer_final.png", to: outputDirectory)
        try writeDebugReceipt(standardSolo, named: "standard_solo_footer_vertical_centered.png", to: outputDirectory)
        try writeDebugReceipt(standardSolo, named: "standard_solo_footer_horizontal_after.png", to: outputDirectory)
        try writeDebugReceipt(standardSolo, named: "standard_solo_footer_edge_selected.png", to: outputDirectory)
        try writeDebugReceipt(standardDuo, named: "standard_duo_footer_final.png", to: outputDirectory)
        try writeDebugReceipt(eventSolo, named: "event_solo_footer_final.png", to: outputDirectory)
        try writeDebugReceipt(eventGrid, named: "event_grid_footer_final.png", to: outputDirectory)

        for format in BoothFormat.allCases {
            let standard = try makeLayoutPlan(format: format, includesGalleryQRCode: true, eventProfile: nil)
            let event = try makeLayoutPlan(format: format, includesGalleryQRCode: true, eventProfile: eventProfile)
            print("RECEIPT standard_\(format.rawValue)=\(standard.width)x\(standard.height) event_\(format.rawValue)=\(event.width)x\(event.height) max=\(BoothConfiguration.receiptMaximumHeight)")
        }
    }

    nonisolated private static func renderDebugFooter(
        metrics: ReceiptFooterMetrics,
        date: Date,
        sessionIdentifier: String,
        galleryURL: URL
    ) throws -> (layout: ReceiptFooterLayout, image: UIImage) {
        let width = BoothConfiguration.receiptWidth
        let layout = makeCompactGalleryFooterLayout(
            photoBottom: 0,
            margin: BoothConfiguration.receiptHorizontalMargin,
            width: width,
            metrics: metrics
        )
        let qrImage = try GalleryQRCodeGenerator.makeQRCodeImage(for: galleryURL, pixelSize: metrics.qrSize)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: CGSize(width: width, height: layout.height), format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: layout.height))
            drawDivider(y: layout.dividerY, margin: BoothConfiguration.receiptHorizontalMargin, width: width)
            context.cgContext.interpolationQuality = .none
            qrImage.draw(in: layout.qrRect)
            drawMeasuredText("SCAN TO VIEW", in: layout.ctaFrame, font: footerCTAFont(size: metrics.ctaFontSize), tracking: metrics.ctaTracking)
            drawMeasuredText("& SAVE YOUR PHOTOS", in: layout.subCTAFrame, font: footerSubCTAFont(size: metrics.subCTAFontSize), tracking: metrics.subCTATracking)
            drawMeasuredText(receiptDateFormatter.string(from: date).uppercased(), in: layout.metadataFrame, font: footerMetadataFont)
            drawMeasuredText(sessionIdentifier, in: layout.sessionFrame, font: footerSessionFont)
            drawBrandClosing(layout: layout)
        }
        return (layout, image)
    }

    nonisolated private static func renderHorizontalBeforeDebugFooter(
        date: Date,
        sessionIdentifier: String,
        galleryURL: URL
    ) throws -> (layout: ReceiptFooterLayout, image: UIImage) {
        let metrics = ReceiptFooterMetrics.production
        let width = BoothConfiguration.receiptWidth
        let layout = makeLegacyHorizontalDebugFooterLayout(
            photoBottom: 0,
            margin: BoothConfiguration.receiptHorizontalMargin,
            width: width,
            metrics: metrics
        )
        let qrImage = try GalleryQRCodeGenerator.makeQRCodeImage(for: galleryURL, pixelSize: metrics.qrSize)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: CGSize(width: width, height: layout.height), format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: layout.height))
            drawDivider(y: layout.dividerY, margin: BoothConfiguration.receiptHorizontalMargin, width: width)
            context.cgContext.interpolationQuality = .none
            qrImage.draw(in: layout.qrRect)
            drawMeasuredText("SCAN TO VIEW", in: layout.ctaFrame, font: footerCTAFont)
            drawMeasuredText("& SAVE YOUR PHOTOS", in: layout.subCTAFrame, font: footerSubCTAFont)
            drawMeasuredText(receiptDateFormatter.string(from: date).uppercased(), in: layout.metadataFrame, font: footerMetadataFont)
            drawMeasuredText(sessionIdentifier, in: layout.sessionFrame, font: footerSessionFont)
            drawBrandClosing(layout: layout)
        }
        return (layout, image)
    }

    nonisolated private static func renderEdgeCurrentDebugFooter(
        date: Date,
        sessionIdentifier: String,
        galleryURL: URL
    ) throws -> (layout: ReceiptFooterLayout, image: UIImage) {
        let metrics = ReceiptFooterMetrics.production
        let width = BoothConfiguration.receiptWidth
        let layout = makeCenteredNarrowDebugFooterLayout(
            photoBottom: 0,
            margin: BoothConfiguration.receiptHorizontalMargin,
            width: width,
            metrics: metrics
        )
        let qrImage = try GalleryQRCodeGenerator.makeQRCodeImage(for: galleryURL, pixelSize: metrics.qrSize)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: CGSize(width: width, height: layout.height), format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: layout.height))
            drawDivider(y: layout.dividerY, margin: BoothConfiguration.receiptHorizontalMargin, width: width)
            context.cgContext.interpolationQuality = .none
            qrImage.draw(in: layout.qrRect)
            drawMeasuredText("SCAN TO VIEW", in: layout.ctaFrame, font: footerCTAFont)
            drawMeasuredText("& SAVE YOUR PHOTOS", in: layout.subCTAFrame, font: footerSubCTAFont)
            drawMeasuredText(receiptDateFormatter.string(from: date).uppercased(), in: layout.metadataFrame, font: footerMetadataFont)
            drawMeasuredText(sessionIdentifier, in: layout.sessionFrame, font: footerSessionFont)
            drawBrandClosing(layout: layout)
        }
        return (layout, image)
    }

    nonisolated private static func makeCenteredNarrowDebugFooterLayout(
        photoBottom: Int,
        margin: Int,
        width: Int,
        metrics: ReceiptFooterMetrics
    ) -> ReceiptFooterLayout {
        let contentLeft = margin
        let contentRight = width - margin
        let usableContentWidth = contentRight - contentLeft
        let rightStackMeasuredWidth = Int(ceil([
            measuredTextWidth("SCAN TO VIEW", font: footerCTAFont),
            measuredTextWidth("& SAVE YOUR PHOTOS", font: footerSubCTAFont),
            measuredTextWidth("SEP 7, 2026 • 9:17 AM", font: footerMetadataFont),
            measuredTextWidth("PP-20260907-091754", font: footerSessionFont)
        ].max() ?? 1)) + 6
        let rightStackEffectiveWidth = rightStackMeasuredWidth
        let mainGroupWidth = metrics.qrSize + metrics.gutter + rightStackEffectiveWidth
        let centeredMainGroupX = contentLeft + max(0, (usableContentWidth - mainGroupWidth) / 2)
        let mainGroupX = min(max(contentLeft, centeredMainGroupX + 4), contentRight - mainGroupWidth)
        return makeDebugFooterLayout(
            photoBottom: photoBottom,
            margin: margin,
            width: width,
            metrics: metrics,
            mainGroupX: mainGroupX,
            mainGroupWidth: mainGroupWidth,
            textColumnWidth: rightStackEffectiveWidth,
            ctaFont: footerCTAFont,
            ctaTracking: 0,
            subCTAFont: footerSubCTAFont,
            subCTATracking: 0,
            horizontalOpticalOffset: 4
        )
    }

    nonisolated private static func makeDebugFooterLayout(
        photoBottom: Int,
        margin: Int,
        width: Int,
        metrics: ReceiptFooterMetrics,
        mainGroupX: Int,
        mainGroupWidth: Int,
        textColumnWidth: Int,
        ctaFont: UIFont,
        ctaTracking: CGFloat,
        subCTAFont: UIFont,
        subCTATracking: CGFloat,
        horizontalOpticalOffset: Int
    ) -> ReceiptFooterLayout {
        let dividerY = photoBottom + footerTopDividerPadding
        let mainRowTop = dividerY + 1 + footerContentTopPadding
        let contentLeft = margin
        let contentRight = width - margin
        let qrRect = CGRect(x: mainGroupX, y: mainRowTop, width: metrics.qrSize, height: metrics.qrSize)
        let textColumnX = mainGroupX + metrics.qrSize + metrics.gutter
        let rightStackMeasuredWidth = Int(ceil([
            measuredTextWidth("SCAN TO VIEW", font: ctaFont, tracking: ctaTracking),
            measuredTextWidth("& SAVE YOUR PHOTOS", font: subCTAFont, tracking: subCTATracking),
            measuredTextWidth("SEP 7, 2026 • 9:17 AM", font: footerMetadataFont),
            measuredTextWidth("PP-20260907-091754", font: footerSessionFont)
        ].max() ?? 1)) + 6
        let rightStackHeight = Int(ceil(ctaFont.lineHeight))
            + metrics.ctaLineGap
            + Int(ceil(subCTAFont.lineHeight))
            + metrics.ctaToMetadataGap
            + Int(ceil(footerMetadataFont.lineHeight))
            + metrics.metadataToSessionGap
            + Int(ceil(footerSessionFont.lineHeight))
        let centeredStackOffset = max(0, (metrics.qrSize - rightStackHeight) / 2)
        let rightStackTop = mainRowTop + centeredStackOffset + metrics.rightStackOpticalOffset
        let ctaFrame = textFrame(text: "SCAN TO VIEW", x: textColumnX, y: rightStackTop, font: ctaFont, availableWidth: textColumnWidth, tracking: ctaTracking)
        let subCTAFrame = textFrame(text: "& SAVE YOUR PHOTOS", x: textColumnX, y: Int(ceil(ctaFrame.maxY)) + metrics.ctaLineGap, font: subCTAFont, availableWidth: textColumnWidth, tracking: subCTATracking)
        let metadataFrame = textFrame(text: "SEP 7, 2026 • 9:17 AM", x: textColumnX, y: Int(ceil(subCTAFrame.maxY)) + metrics.ctaToMetadataGap, font: footerMetadataFont, availableWidth: textColumnWidth)
        let sessionFrame = textFrame(text: "PP-20260907-091754", x: textColumnX, y: Int(ceil(metadataFrame.maxY)) + metrics.metadataToSessionGap, font: footerSessionFont, availableWidth: textColumnWidth)
        let rightStackBottom = Int(ceil(sessionFrame.maxY))
        let mainRowBottom = max(Int(ceil(qrRect.maxY)), rightStackBottom)
        let textColumnRect = CGRect(x: textColumnX, y: mainRowTop, width: textColumnWidth, height: max(1, mainRowBottom - mainRowTop))
        let brandRowY = mainRowBottom + metrics.brandTopPadding
        let handleWidth = Int(ceil(measuredTextWidth("@pocketpixels.ceb", font: footerHandleFont))) + 6
        let brandRowWidth = footerHandleMonogramSize + footerHandleMonogramToTextGap + handleWidth
        let brandRowX = (width - brandRowWidth) / 2
        let handleY = brandRowY + Int(floor((CGFloat(footerHandleMonogramSize) - footerHandleFont.lineHeight) / 2)) - 1
        let monogramRect = CGRect(x: brandRowX, y: brandRowY, width: footerHandleMonogramSize, height: footerHandleMonogramSize)
        let closingY = brandRowY + footerBrandRowHeight + metrics.closingTopPadding
        let footerBottom = closingY + footerClosingHeight + metrics.bottomPadding

        return ReceiptFooterLayout(
            top: photoBottom,
            height: footerBottom - photoBottom,
            dividerY: dividerY,
            mainRowTop: mainRowTop,
            contentLeft: contentLeft,
            contentRight: contentRight,
            mainGroupX: mainGroupX,
            mainGroupWidth: mainGroupWidth,
            horizontalOpticalOffset: horizontalOpticalOffset,
            qrRect: qrRect,
            textColumnRect: textColumnRect,
            rightStackMeasuredWidth: rightStackMeasuredWidth,
            rightStackEffectiveWidth: textColumnWidth,
            ctaFrame: ctaFrame,
            subCTAFrame: subCTAFrame,
            metadataFrame: metadataFrame,
            sessionFrame: sessionFrame,
            rightStackBottom: rightStackBottom,
            mainRowBottom: mainRowBottom,
            brandRowY: brandRowY,
            brandRowHeight: footerBrandRowHeight,
            monogramRect: monogramRect,
            handleX: brandRowX + footerHandleMonogramSize + footerHandleMonogramToTextGap,
            handleY: handleY,
            handleWidth: handleWidth,
            brandRowWidth: brandRowWidth,
            closingY: closingY,
            bottomPadding: metrics.bottomPadding
        )
    }

    nonisolated private static func makeLegacyHorizontalDebugFooterLayout(
        photoBottom: Int,
        margin: Int,
        width: Int,
        metrics: ReceiptFooterMetrics
    ) -> ReceiptFooterLayout {
        let legacyMetrics = ReceiptFooterMetrics(
            qrModuleScale: metrics.qrModuleScale,
            qrSize: metrics.qrSize,
            gutter: metrics.gutter,
            mainGroupHorizontalOpticalOffset: metrics.mainGroupHorizontalOpticalOffset,
            ctaFontSize: metrics.ctaFontSize,
            ctaTracking: metrics.ctaTracking,
            subCTAFontSize: metrics.subCTAFontSize,
            subCTATracking: metrics.subCTATracking,
            ctaLineGap: metrics.ctaLineGap,
            ctaToMetadataGap: metrics.ctaToMetadataGap,
            metadataToSessionGap: metrics.metadataToSessionGap,
            rightStackOpticalOffset: metrics.rightStackOpticalOffset,
            brandTopPadding: metrics.brandTopPadding,
            closingTopPadding: metrics.closingTopPadding,
            bottomPadding: metrics.bottomPadding
        )
        let dividerY = photoBottom + footerTopDividerPadding
        let mainRowTop = dividerY + 1 + footerContentTopPadding
        let contentLeft = margin
        let contentRight = width - margin
        let qrRect = CGRect(x: margin, y: mainRowTop, width: legacyMetrics.qrSize, height: legacyMetrics.qrSize)
        let textColumnX = margin + legacyMetrics.qrSize + legacyMetrics.gutter
        let rightStackMeasuredWidth = Int(ceil([
            measuredTextWidth("SCAN TO VIEW", font: footerCTAFont),
            measuredTextWidth("& SAVE YOUR PHOTOS", font: footerSubCTAFont),
            measuredTextWidth("SEP 7, 2026 • 9:17 AM", font: footerMetadataFont),
            measuredTextWidth("PP-20260907-091754", font: footerSessionFont)
        ].max() ?? 1)) + 6
        let textColumnWidth = max(1, contentRight - textColumnX)
        let rightStackEffectiveWidth = min(rightStackMeasuredWidth, textColumnWidth)
        let rightStackHeight = Int(ceil(footerCTAFont.lineHeight))
            + legacyMetrics.ctaLineGap
            + Int(ceil(footerSubCTAFont.lineHeight))
            + legacyMetrics.ctaToMetadataGap
            + Int(ceil(footerMetadataFont.lineHeight))
            + legacyMetrics.metadataToSessionGap
            + Int(ceil(footerSessionFont.lineHeight))
        let centeredStackOffset = max(0, (legacyMetrics.qrSize - rightStackHeight) / 2)
        let rightStackTop = mainRowTop + centeredStackOffset + legacyMetrics.rightStackOpticalOffset
        let ctaFrame = textFrame(text: "SCAN TO VIEW", x: textColumnX, y: rightStackTop, font: footerCTAFont, availableWidth: textColumnWidth)
        let subCTAFrame = textFrame(text: "& SAVE YOUR PHOTOS", x: textColumnX, y: Int(ceil(ctaFrame.maxY)) + legacyMetrics.ctaLineGap, font: footerSubCTAFont, availableWidth: textColumnWidth)
        let metadataFrame = textFrame(text: "SEP 7, 2026 • 9:17 AM", x: textColumnX, y: Int(ceil(subCTAFrame.maxY)) + legacyMetrics.ctaToMetadataGap, font: footerMetadataFont, availableWidth: textColumnWidth)
        let sessionFrame = textFrame(text: "PP-20260907-091754", x: textColumnX, y: Int(ceil(metadataFrame.maxY)) + legacyMetrics.metadataToSessionGap, font: footerSessionFont, availableWidth: textColumnWidth)
        let rightStackBottom = Int(ceil(sessionFrame.maxY))
        let mainRowBottom = max(Int(ceil(qrRect.maxY)), rightStackBottom)
        let textColumnRect = CGRect(x: textColumnX, y: mainRowTop, width: textColumnWidth, height: max(1, mainRowBottom - mainRowTop))
        let brandRowY = mainRowBottom + legacyMetrics.brandTopPadding
        let handleWidth = Int(ceil(measuredTextWidth("@pocketpixels.ceb", font: footerHandleFont))) + 6
        let brandRowWidth = footerHandleMonogramSize + footerHandleMonogramToTextGap + handleWidth
        let brandRowX = (width - brandRowWidth) / 2
        let handleY = brandRowY + Int(floor((CGFloat(footerHandleMonogramSize) - footerHandleFont.lineHeight) / 2)) - 1
        let monogramRect = CGRect(x: brandRowX, y: brandRowY, width: footerHandleMonogramSize, height: footerHandleMonogramSize)
        let closingY = brandRowY + footerBrandRowHeight + legacyMetrics.closingTopPadding
        let footerBottom = closingY + footerClosingHeight + legacyMetrics.bottomPadding
        let mainGroupWidth = legacyMetrics.qrSize + legacyMetrics.gutter + rightStackEffectiveWidth

        return ReceiptFooterLayout(
            top: photoBottom,
            height: footerBottom - photoBottom,
            dividerY: dividerY,
            mainRowTop: mainRowTop,
            contentLeft: contentLeft,
            contentRight: contentRight,
            mainGroupX: margin,
            mainGroupWidth: mainGroupWidth,
            horizontalOpticalOffset: 0,
            qrRect: qrRect,
            textColumnRect: textColumnRect,
            rightStackMeasuredWidth: rightStackMeasuredWidth,
            rightStackEffectiveWidth: rightStackEffectiveWidth,
            ctaFrame: ctaFrame,
            subCTAFrame: subCTAFrame,
            metadataFrame: metadataFrame,
            sessionFrame: sessionFrame,
            rightStackBottom: rightStackBottom,
            mainRowBottom: mainRowBottom,
            brandRowY: brandRowY,
            brandRowHeight: footerBrandRowHeight,
            monogramRect: monogramRect,
            handleX: brandRowX + footerHandleMonogramSize + footerHandleMonogramToTextGap,
            handleY: handleY,
            handleWidth: handleWidth,
            brandRowWidth: brandRowWidth,
            closingY: closingY,
            bottomPadding: legacyMetrics.bottomPadding
        )
    }

    nonisolated private static func writeDebugReceipt(_ receipt: ComposedReceipt, named name: String, to outputDirectory: URL) throws {
        guard let image = UIImage(data: receipt.imagePNGData) else {
            throw debugSelfCheckFailure("Could not create debug receipt image for \(name).")
        }
        try writeDebugImage(image, named: name, to: outputDirectory)
    }

    nonisolated private static func writeDebugImage(_ image: UIImage, named name: String, to outputDirectory: URL) throws {
        guard let data = image.pngData() else {
            throw debugSelfCheckFailure("Could not encode debug image \(name).")
        }
        let url = outputDirectory.appendingPathComponent(name)
        try data.write(to: url)
        print("ARTIFACT \(url.path) \(Int(image.size.width))x\(Int(image.size.height))")
    }

    nonisolated private static func makeBeforeAfterDebugImage(before: UIImage, after: UIImage) -> UIImage {
        let width = BoothConfiguration.receiptWidth
        let gap = 16
        let height = Int(before.size.height + after.size.height) + gap
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            before.draw(at: .zero)
            after.draw(at: CGPoint(x: 0, y: Int(before.size.height) + gap))
        }
    }

    nonisolated private static func makeDebugReceiptPhotos() -> [UIImage] {
        [
            makeDebugReceiptPhoto(width: 900, height: 1_200, hue: 0.22),
            makeDebugReceiptPhoto(width: 1_200, height: 900, hue: 0.48),
            makeDebugReceiptPhoto(width: 900, height: 1_200, hue: 0.08),
            makeDebugReceiptPhoto(width: 900, height: 1_200, hue: 0.75)
        ]
    }

    nonisolated private static func makeDebugReceiptDate() -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = sessionIdentifierTimeZone
        return calendar.date(from: DateComponents(
            timeZone: sessionIdentifierTimeZone,
            year: 2026,
            month: 9,
            day: 7,
            hour: 9,
            minute: 17,
            second: 54
        )) ?? Date(timeIntervalSince1970: 1_788_743_874)
    }

    nonisolated private static func makeDebugReceiptPhoto(width: Int, height: Int, hue: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
            UIColor(hue: hue, saturation: 0.45, brightness: 0.95, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            UIColor(hue: hue + 0.08, saturation: 0.55, brightness: 0.55, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: height / 3, width: width, height: height / 3))
            UIColor.white.withAlphaComponent(0.45).setFill()
            context.fill(CGRect(x: width / 5, y: height / 7, width: width / 2, height: height / 3))
        }
    }

    nonisolated private static func printDebugLayout(_ label: String, _ layout: ReceiptFooterLayout) {
        let gaps = [
            Int(layout.subCTAFrame.minY - layout.ctaFrame.maxY),
            Int(layout.metadataFrame.minY - layout.subCTAFrame.maxY),
            Int(layout.sessionFrame.minY - layout.metadataFrame.maxY)
        ]
        let topSpace = Int(layout.ctaFrame.minY - layout.qrRect.minY)
        let bottomSpace = Int(layout.qrRect.maxY - layout.sessionFrame.maxY)
        let stackHeight = Int(layout.sessionFrame.maxY - layout.ctaFrame.minY)
        let leftSpace = layout.mainGroupX - layout.contentLeft
        let rightSpace = layout.contentRight - (layout.mainGroupX + layout.mainGroupWidth)
        print("METRIC \(label) contentLeft=\(layout.contentLeft) contentRight=\(layout.contentRight) usableWidth=\(layout.contentRight - layout.contentLeft) footerHeight=\(layout.height) qr=\(Int(layout.qrRect.width)) gutter=\(Int(layout.textColumnRect.minX - layout.qrRect.maxX)) groupX=\(layout.mainGroupX) groupWidth=\(layout.mainGroupWidth) leftSpace=\(leftSpace) rightSpace=\(rightSpace) horizontalOpticalOffset=\(layout.horizontalOpticalOffset) rightMeasuredW=\(layout.rightStackMeasuredWidth) rightEffectiveW=\(layout.rightStackEffectiveWidth) largestGap=\(gaps.max() ?? 0) stackTop=\(Int(layout.ctaFrame.minY)) stackBottom=\(Int(layout.sessionFrame.maxY)) stackHeight=\(stackHeight) topSpace=\(topSpace) bottomSpace=\(bottomSpace) rightTop=\(Int(layout.textColumnRect.minY)) cta=\(Int(layout.ctaFrame.minY))-\(Int(layout.ctaFrame.maxY))x\(Int(ceil(layout.ctaFrame.width))) sub=\(Int(layout.subCTAFrame.minY))-\(Int(layout.subCTAFrame.maxY))x\(Int(ceil(layout.subCTAFrame.width))) meta=\(Int(layout.metadataFrame.minY))-\(Int(layout.metadataFrame.maxY))x\(Int(ceil(layout.metadataFrame.width))) session=\(Int(layout.sessionFrame.minY))-\(Int(layout.sessionFrame.maxY))x\(Int(ceil(layout.sessionFrame.width))) mainTop=\(layout.mainRowTop) mainBottom=\(layout.mainRowBottom) brandY=\(layout.brandRowY) closingY=\(layout.closingY) textX=\(Int(layout.textColumnRect.minX)) textW=\(Int(layout.textColumnRect.width)) qrRect=\(Int(layout.qrRect.minX)),\(Int(layout.qrRect.minY)),\(Int(layout.qrRect.width)),\(Int(layout.qrRect.height)) monogram=\(Int(layout.monogramRect.minX)),\(Int(layout.monogramRect.minY)),\(Int(layout.monogramRect.width)),\(Int(layout.monogramRect.height)) handle=\(layout.handleX),\(layout.handleY),\(layout.handleWidth) brandWidth=\(layout.brandRowWidth)")
    }
#endif

    nonisolated private static func compactGalleryFooterHeight(qrSize: Int) -> Int {
        makeCompactGalleryFooterLayout(
            photoBottom: 0,
            margin: BoothConfiguration.receiptHorizontalMargin,
            width: BoothConfiguration.receiptWidth,
            metrics: ReceiptFooterMetrics(
                qrModuleScale: ReceiptFooterMetrics.production.qrModuleScale,
                qrSize: qrSize,
                gutter: ReceiptFooterMetrics.production.gutter,
                mainGroupHorizontalOpticalOffset: ReceiptFooterMetrics.production.mainGroupHorizontalOpticalOffset,
                ctaFontSize: ReceiptFooterMetrics.production.ctaFontSize,
                ctaTracking: ReceiptFooterMetrics.production.ctaTracking,
                subCTAFontSize: ReceiptFooterMetrics.production.subCTAFontSize,
                subCTATracking: ReceiptFooterMetrics.production.subCTATracking,
                ctaLineGap: ReceiptFooterMetrics.production.ctaLineGap,
                ctaToMetadataGap: ReceiptFooterMetrics.production.ctaToMetadataGap,
                metadataToSessionGap: ReceiptFooterMetrics.production.metadataToSessionGap,
                rightStackOpticalOffset: ReceiptFooterMetrics.production.rightStackOpticalOffset,
                brandTopPadding: ReceiptFooterMetrics.production.brandTopPadding,
                closingTopPadding: ReceiptFooterMetrics.production.closingTopPadding,
                bottomPadding: ReceiptFooterMetrics.production.bottomPadding
            )
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
        metrics: ReceiptFooterMetrics
    ) -> ReceiptFooterLayout {
        let dividerY = photoBottom + footerTopDividerPadding
        let mainRowTop = dividerY + 1 + footerContentTopPadding
        let contentLeft = margin
        let contentRight = width - margin
        let usableContentWidth = contentRight - contentLeft
        let ctaFont = footerCTAFont(size: metrics.ctaFontSize)
        let subCTAFont = footerSubCTAFont(size: metrics.subCTAFontSize)
        let rightStackMeasuredWidth = Int(ceil([
            measuredTextWidth("SCAN TO VIEW", font: ctaFont, tracking: metrics.ctaTracking),
            measuredTextWidth("& SAVE YOUR PHOTOS", font: subCTAFont, tracking: metrics.subCTATracking),
            measuredTextWidth("SEP 7, 2026 • 9:17 AM", font: footerMetadataFont),
            measuredTextWidth("PP-20260907-091754", font: footerSessionFont)
        ].max() ?? 1)) + 6
        let maxRightStackWidth = max(1, usableContentWidth - metrics.qrSize - metrics.gutter)
        let rightStackEffectiveWidth = maxRightStackWidth
        let mainGroupWidth = usableContentWidth
        let mainGroupX = contentLeft
        let qrRect = CGRect(x: mainGroupX, y: mainRowTop, width: metrics.qrSize, height: metrics.qrSize)
        let textColumnX = mainGroupX + metrics.qrSize + metrics.gutter
        let textColumnWidth = rightStackEffectiveWidth
        let rightStackHeight = Int(ceil(ctaFont.lineHeight))
            + metrics.ctaLineGap
            + Int(ceil(subCTAFont.lineHeight))
            + metrics.ctaToMetadataGap
            + Int(ceil(footerMetadataFont.lineHeight))
            + metrics.metadataToSessionGap
            + Int(ceil(footerSessionFont.lineHeight))
        let centeredStackOffset = max(0, (metrics.qrSize - rightStackHeight) / 2)
        let rightStackTop = mainRowTop + centeredStackOffset + metrics.rightStackOpticalOffset
        let ctaFrame = textFrame(
            text: "SCAN TO VIEW",
            x: textColumnX,
            y: rightStackTop,
            font: ctaFont,
            availableWidth: textColumnWidth,
            tracking: metrics.ctaTracking
        )
        let subCTAFrame = textFrame(
            text: "& SAVE YOUR PHOTOS",
            x: textColumnX,
            y: Int(ceil(ctaFrame.maxY)) + metrics.ctaLineGap,
            font: subCTAFont,
            availableWidth: textColumnWidth,
            tracking: metrics.subCTATracking
        )
        let metadataFrame = textFrame(
            text: "SEP 7, 2026 • 9:17 AM",
            x: textColumnX,
            y: Int(ceil(subCTAFrame.maxY)) + metrics.ctaToMetadataGap,
            font: footerMetadataFont,
            availableWidth: textColumnWidth
        )
        let sessionFrame = textFrame(
            text: "PP-20260907-091754",
            x: textColumnX,
            y: Int(ceil(metadataFrame.maxY)) + metrics.metadataToSessionGap,
            font: footerSessionFont,
            availableWidth: textColumnWidth
        )
        let rightStackBottom = Int(ceil(sessionFrame.maxY))
        let mainRowBottom = max(Int(ceil(qrRect.maxY)), rightStackBottom)
        let textColumnRect = CGRect(
            x: textColumnX,
            y: mainRowTop,
            width: textColumnWidth,
            height: max(1, mainRowBottom - mainRowTop)
        )

        let brandRowY = mainRowBottom + metrics.brandTopPadding
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
        let closingY = brandRowY + footerBrandRowHeight + metrics.closingTopPadding
        let footerBottom = closingY + footerClosingHeight + metrics.bottomPadding

        return ReceiptFooterLayout(
            top: photoBottom,
            height: footerBottom - photoBottom,
            dividerY: dividerY,
            mainRowTop: mainRowTop,
            contentLeft: contentLeft,
            contentRight: contentRight,
            mainGroupX: mainGroupX,
            mainGroupWidth: mainGroupWidth,
            horizontalOpticalOffset: metrics.mainGroupHorizontalOpticalOffset,
            qrRect: qrRect,
            textColumnRect: textColumnRect,
            rightStackMeasuredWidth: rightStackMeasuredWidth,
            rightStackEffectiveWidth: rightStackEffectiveWidth,
            ctaFrame: ctaFrame,
            subCTAFrame: subCTAFrame,
            metadataFrame: metadataFrame,
            sessionFrame: sessionFrame,
            rightStackBottom: rightStackBottom,
            mainRowBottom: mainRowBottom,
            brandRowY: brandRowY,
            brandRowHeight: footerBrandRowHeight,
            monogramRect: monogramRect,
            handleX: brandRowX + footerHandleMonogramSize + footerHandleMonogramToTextGap,
            handleY: handleY,
            handleWidth: handleWidth,
            brandRowWidth: brandRowWidth,
            closingY: closingY,
            bottomPadding: metrics.bottomPadding
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
        let metrics = ReceiptFooterMetrics(
            qrModuleScale: ReceiptFooterMetrics.production.qrModuleScale,
                qrSize: qrSize,
            gutter: ReceiptFooterMetrics.production.gutter,
            mainGroupHorizontalOpticalOffset: ReceiptFooterMetrics.production.mainGroupHorizontalOpticalOffset,
            ctaFontSize: ReceiptFooterMetrics.production.ctaFontSize,
            ctaTracking: ReceiptFooterMetrics.production.ctaTracking,
            subCTAFontSize: ReceiptFooterMetrics.production.subCTAFontSize,
            subCTATracking: ReceiptFooterMetrics.production.subCTATracking,
                ctaLineGap: ReceiptFooterMetrics.production.ctaLineGap,
            ctaToMetadataGap: ReceiptFooterMetrics.production.ctaToMetadataGap,
            metadataToSessionGap: ReceiptFooterMetrics.production.metadataToSessionGap,
            rightStackOpticalOffset: ReceiptFooterMetrics.production.rightStackOpticalOffset,
            brandTopPadding: ReceiptFooterMetrics.production.brandTopPadding,
            closingTopPadding: ReceiptFooterMetrics.production.closingTopPadding,
            bottomPadding: ReceiptFooterMetrics.production.bottomPadding
        )
        let layout = makeCompactGalleryFooterLayout(photoBottom: photoBottom, margin: margin, width: width, metrics: metrics)
        drawDivider(y: layout.dividerY, margin: margin, width: width)

        context.interpolationQuality = .none
        qrImage.draw(in: layout.qrRect)

        drawMeasuredText("SCAN TO VIEW", in: layout.ctaFrame, font: footerCTAFont(size: metrics.ctaFontSize), tracking: metrics.ctaTracking)
        drawMeasuredText("& SAVE YOUR PHOTOS", in: layout.subCTAFrame, font: footerSubCTAFont(size: metrics.subCTAFontSize), tracking: metrics.subCTATracking)
        drawMeasuredText(receiptDateFormatter.string(from: date).uppercased(), in: layout.metadataFrame, font: footerMetadataFont)
        drawMeasuredText(sessionIdentifier, in: layout.sessionFrame, font: footerSessionFont)

        drawBrandClosing(layout: layout)
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

    nonisolated private static func drawMeasuredText(_ text: String, in frame: CGRect, font: UIFont) {
        drawText(
            text,
            x: Int(frame.minX),
            y: Int(frame.minY),
            font: font,
            alignment: .left,
            width: Int(ceil(frame.width))
        )
    }

    nonisolated private static func drawMeasuredText(_ text: String, in frame: CGRect, font: UIFont, tracking: CGFloat) {
        drawText(
            text,
            x: Int(frame.minX),
            y: Int(frame.minY),
            font: font,
            alignment: .left,
            width: Int(ceil(frame.width)),
            tracking: tracking
        )
    }

    nonisolated private static func textFrame(
        text: String,
        x: Int,
        y: Int,
        font: UIFont,
        availableWidth: Int,
        tracking: CGFloat = 0
    ) -> CGRect {
        let measuredWidth = Int(ceil(measuredTextWidth(text, font: font, tracking: tracking))) + 6
        return CGRect(
            x: x,
            y: y,
            width: min(measuredWidth, availableWidth),
            height: Int(ceil(font.lineHeight))
        )
    }

    nonisolated private static func drawText(_ text: String, x: Int, y: Int, font: UIFont, alignment: NSTextAlignment, width: Int) {
        drawText(text, x: x, y: y, font: font, alignment: alignment, width: width, tracking: 0)
    }

    nonisolated private static func drawText(_ text: String, x: Int, y: Int, font: UIFont, alignment: NSTextAlignment, width: Int, tracking: CGFloat) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .kern: tracking,
            .foregroundColor: UIColor.black,
            .paragraphStyle: paragraph
        ]

        NSString(string: text).draw(
            in: CGRect(x: x, y: y, width: width, height: Int(font.lineHeight) + 8),
            withAttributes: attributes
        )
    }

    nonisolated private static func measuredTextWidth(_ text: String, font: UIFont) -> CGFloat {
        measuredTextWidth(text, font: font, tracking: 0)
    }

    nonisolated private static func measuredTextWidth(_ text: String, font: UIFont, tracking: CGFloat) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .kern: tracking
        ]
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

#if DEBUG
    nonisolated private static func largestRightColumnGap(in layout: ReceiptFooterLayout) -> Int {
        let gaps = [
            Int(layout.subCTAFrame.minY - layout.ctaFrame.maxY),
            Int(layout.metadataFrame.minY - layout.subCTAFrame.maxY),
            Int(layout.sessionFrame.minY - layout.metadataFrame.maxY)
        ]
        return gaps.max() ?? 0
    }

    nonisolated private static func rightStackTopPadding(in layout: ReceiptFooterLayout) -> Int {
        Int(layout.ctaFrame.minY - layout.qrRect.minY)
    }

    nonisolated private static func rightStackBottomPadding(in layout: ReceiptFooterLayout) -> Int {
        Int(layout.qrRect.maxY - layout.sessionFrame.maxY)
    }
#endif

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

    nonisolated private static func footerCTAFont(size: CGFloat) -> UIFont {
        .systemFont(ofSize: size, weight: .bold)
    }

    nonisolated private static var footerSubCTAFont: UIFont {
        .systemFont(ofSize: 20, weight: .semibold)
    }

    nonisolated private static func footerSubCTAFont(size: CGFloat) -> UIFont {
        .systemFont(ofSize: size, weight: .semibold)
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
