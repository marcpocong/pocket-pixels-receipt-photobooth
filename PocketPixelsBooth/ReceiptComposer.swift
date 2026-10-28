//
//  ReceiptComposer.swift
//  PocketPixelsBooth
//
//  Composes the Made to Keep Studios receipt: masthead (or event artwork), photographs, the
//  QR or classic barcode footer, an optional
//  supplementary area (event caption, artwork signature, event details, studio credit) and an
//  optional, visually separate gallery QR section. Photo Pass sits under the same masthead;
//  Passport / Photo Pass keep their own cards and share everything from the footer down.
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
    /// Whether this exact composition carries the gallery QR. Frozen with the print.
    var includesPrintedGalleryQR: Bool = false
    /// Measured sticker-safe regions of this exact composition (photos and approved blank bands).
    var stickerLayout: StickerLayoutSnapshot? = nil
    /// Stickers drawn into this composition, in z-order. Empty when none were placed.
    var drawnStickerPlacementIDs: [UUID] = []

    nonisolated var estimatedLengthMillimeters: Double {
        Double(height) / 8.0
    }
}

struct ReceiptPhotoFrame: Sendable {
    let photoIndex: Int
    let rect: CGRect
}

/// Single-line receipt text roles. Each maps to one print-tested face.
nonisolated enum ReceiptTextStyle: String, Sendable, Equatable {
    case wordmark
    case studios
    case caption
    /// Session date and time in the footer's right column.
    case footer
    case sessionIdentifier
    case qrLabel
    case creditWordmark
    case creditStudios
}

/// A measured single line of receipt text. `rect` starts at the first glyph's origin; the text is
/// drawn from `rect.origin` and never wraps.
nonisolated struct ReceiptTextFrame: Sendable, Equatable {
    let style: ReceiptTextStyle
    let text: String
    let rect: CGRect
    let fontSize: CGFloat
    let tracking: CGFloat
}

private enum ReceiptTextAnchor {
    case leading(CGFloat)
    case center(CGFloat)
    case trailing(CGFloat)
}

private struct ReceiptTextSnapshot: Sendable {
    /// Event details after de-duplication against the editorial caption.
    let eventContent: EventReceiptBlockContent?
    let eventTypography: ResolvedEventTypography
    /// Normalized header configuration. A legacy custom header whose asset is missing has
    /// already been switched to the Made to Keep masthead.
    let headerConfiguration: ReceiptHeaderConfiguration
    let headerSourceSize: CGSize?
    /// Visible content of the header artwork (padding excluded); Co-Branded sizes by this.
    let headerContentBounds: CGRect?
    let branding: ReceiptBrandingResolution
    let captionLines: [String]
    /// Frozen session date and time, e.g. `OCT 13 2026` / `2:50 AM` (Asia/Manila).
    let footerDateLines: [String]
    let sessionIdentifier: String
    let qrLabel: String
}

private struct ReceiptHeaderLayout: Sendable {
    let mode: ReceiptHeaderMode
    let startY: Int
    let mastheadTexts: [ReceiptTextFrame]
    let customImageFrame: CGRect?
    /// Legacy event text block below the header, laid out with the frozen session typography.
    let eventTextFrames: [EventTextBlockFrame]
    /// Legacy headers keep their divider above the photographs.
    let dividerY: Int?
    let bottom: Int
    /// Co-Branded only: the × between the Made to Keep wordmark and the event logo.
    var coBrandSeparator: CGRect? = nil
}

/// Footer geometry for either the integrated gallery code or the historical barcode columns.
/// QR frames include the white quiet zone.
nonisolated struct ReceiptFooterLayout: Sendable {
    var integratedQRFrame: CGRect? = nil
    var integratedQRLabel: ReceiptTextFrame? = nil
    let barcodeFrame: CGRect
    let barcodeBars: [CGRect]
    let separatorFrames: [CGRect]
    let monogramFrame: CGRect
    let dateTexts: [ReceiptTextFrame]
    let top: Int
    let bottom: Int

    /// Every printed footer element, left to right.
    var elementFrames: [CGRect] {
        [integratedQRFrame ?? barcodeFrame] + separatorFrames + [monogramFrame]
            + dateTexts.map(\.rect) + [integratedQRLabel?.rect].compactMap { $0 }
    }
}

/// Everything from the end of the photographs (or cards) to the bottom of the paper.
private struct ReceiptEditorialLayout: Sendable {
    let footer: ReceiptFooterLayout
    let captionTexts: [ReceiptTextFrame]
    let signatureFrame: CGRect?
    let eventTextFrames: [EventTextBlockFrame]
    let creditTexts: [ReceiptTextFrame]
    let qrSeparator: CGRect?
    let qrRect: CGRect?
    let qrLabel: ReceiptTextFrame?
    let sessionText: ReceiptTextFrame
    let bottom: Int
}

struct ReceiptLayoutPlan: Sendable {
    let format: BoothFormat
    fileprivate let textSnapshot: ReceiptTextSnapshot
    fileprivate let headerLayout: ReceiptHeaderLayout
    fileprivate let editorialLayout: ReceiptEditorialLayout
    let displayedPhotoIndexes: [Int]
    let photoFrames: [ReceiptPhotoFrame]
    let groupFrame: CGRect?
    let width: Int
    let height: Int
    let previewContentHeight: Int
    /// Printed QR edge length in dots; 0 when the receipt prints without a QR.
    let qrSize: Int
    let includesPrintedGalleryQR: Bool
    let qrRect: CGRect?
    let headerMode: ReceiptHeaderMode
    let branding: ReceiptBrandingResolution
    /// Event artwork at the top of the receipt (legacy header, Event-First, or a legacy Passport card).
    let customHeaderFrame: CGRect?
    /// Event artwork printed as the compact Studio-First signature below the footer.
    let eventSignatureFrame: CGRect?
    /// Co-Branded only: the × centred between the wordmark (`mastheadFrames`) and the logo
    /// (`customHeaderFrame`).
    let coBrandSeparatorFrame: CGRect?
    let mastheadFrames: [CGRect]
    let captionLines: [String]
    let captionFrames: [CGRect]
    /// The three-part footer exactly as printed.
    let footer: ReceiptFooterLayout
    /// Every footer element: barcode, both rules, monogram and the date/time lines.
    let footerFrames: [CGRect]
    let studioCreditFrames: [CGRect]
    let sessionIdentifierFrame: CGRect
    let showsEventTextBlock: Bool
    /// Event text block frames wherever they print (empty when hidden and for Passport).
    let eventTextFrames: [EventTextBlockFrame]
    /// Legacy Passport cards replace the masthead and the standard photo stack; nil for other
    /// formats and for Photo Pass sessions.
    let passportLayout: PassportReceiptLayout?
    let passportContent: PassportReceiptContent?
    /// Photo Pass (Passport design v2) cards; nil for other formats and legacy Passport sessions.
    let photoPassLayout: PhotoPassReceiptLayout?
    let photoPassContent: PhotoPassContent?
    /// Bottom of the photo/card section; the editorial section always starts here.
    let contentBottom: Int
    /// Bottom of the date/time footer.
    let footerBottom: Int
}

enum ReceiptComposerError: Error, LocalizedError {
    case missingPhotos(expected: Int, actual: Int)
    case renderFailed
    case heightExceeded(Int)
    case invalidLayout(String)

    var errorDescription: String? {
        switch self {
        case .missingPhotos(let expected, let actual):
            "Receipt requires \(expected) photos, but \(actual) are available."
        case .renderFailed:
            "The receipt could not be rendered."
        case .heightExceeded(let height):
            "The composed receipt is too tall: \(height) pixels."
        case .invalidLayout(let message):
            "The receipt layout is invalid: \(message)"
        }
    }
}

enum ReceiptComposer {
    /// Studio descriptor. No longer printed above the wordmark; kept as the brand constant.
    nonisolated static let mastheadEstablishedText = MadeToKeepBrand.descriptor
    /// Brand tagline. The editorial footer no longer prints it; kept as the brand constant.
    nonisolated static let footerBrandLine = MadeToKeepBrand.tagline
    nonisolated static let printedQRLabel = "SCAN TO SAVE YOUR PHOTOS"
    /// Fill-plus-stroke (percent of point size) that keeps high-contrast serif hairlines solid
    /// after 1-bit thermal rasterization.
    nonisolated private static let thermalSerifStrokeWidth: CGFloat = -2.2

    nonisolated static let sessionIdentifierTimeZone = TimeZone(identifier: "Asia/Manila") ?? TimeZone(secondsFromGMT: 8 * 60 * 60)!
    /// Centered QR at four printer dots per module for the production gallery URL.
    nonisolated static let receiptQRCodeSize = 236
    nonisolated static let landscapePresentationCropAspectRatio = CGSize(width: 4, height: 3)
    nonisolated static let landscapePresentationAspectRatio = landscapePresentationCropAspectRatio.width / landscapePresentationCropAspectRatio.height
    nonisolated static let stripPresentationCropAspectRatio = landscapePresentationCropAspectRatio

    /// Print geometry in printer dots (8 dots/mm), measured from the Made to Keep reference
    /// receipt and shared by every format.
    private enum Metrics {
        nonisolated static let receiptTopPadding = 14
        // Keep the digital inset compact while preserving a clear masthead border.
        // Physical printer clearance is separate from this rendered padding.
        nonisolated static let mastheadTopInset = 8
        nonisolated static let wordmarkSize: CGFloat = 55
        nonisolated static let studiosSize: CGFloat = 14
        nonisolated static let studiosTracking: CGFloat = 8.5
        nonisolated static let wordmarkStudiosGap = -4
        nonisolated static let mastheadPhotoGap = 44
        nonisolated static let topArtworkPhotoGap = 16
        /// Photographs sit inside generous white side margins like the reference.
        nonisolated static let photoMargin = 36
        nonisolated static let photoGutter = 12
        // Three-part footer. Columns are measured from the paper centre so the monogram is
        // always centred; the outer columns align with the photo margins.
        nonisolated static let photoFooterGap = 56
        nonisolated static let footerSideInset = photoMargin
        nonisolated static let footerRowHeight = 52
        nonisolated static let footerMonogramHeight = 72
        nonisolated static let footerSeparatorOffset = 88
        nonisolated static let footerSeparatorWidth = 2
        nonisolated static let footerDateSize: CGFloat = 16
        nonisolated static let footerDateTracking: CGFloat = 1
        nonisolated static let footerDateLineGap = 8
        /// Minimum clear space between a footer column and a rule.
        nonisolated static let footerColumnClearance = 16
        // Optional event caption in the supplementary area: small, tracked, no hairlines.
        nonisolated static let captionMaximumWidth: CGFloat = 404
        nonisolated static let captionSizes: [CGFloat] = [15, 14, 13]
        nonisolated static let captionTracking: CGFloat = 4.6
        nonisolated static let captionLineGap = 7
        nonisolated static let secondaryGap = 40
        nonisolated static let secondaryInnerGap = 18
        nonisolated static let eventTextInset = 60
        nonisolated static let creditWordmarkSize: CGFloat = 32
        nonisolated static let creditStudiosSize: CGFloat = 11
        nonisolated static let creditStudiosTracking: CGFloat = 6
        // Keep measured line boxes separate even though the visible glyphs remain optically close.
        nonisolated static let creditStudiosGap = 0
        nonisolated static let qrSectionGap = 40
        nonisolated static let qrSeparatorDash: CGFloat = 6
        nonisolated static let qrSeparatorThickness = 2
        nonisolated static let qrSeparatorGap = 26
        nonisolated static let qrLabelGap = 12
        nonisolated static let qrLabelSize: CGFloat = 14
        nonisolated static let qrLabelTracking: CGFloat = 3.4
        nonisolated static let sessionGap = 26
        nonisolated static let sessionSize: CGFloat = 11.5
        nonisolated static let sessionTracking: CGFloat = 1
        // Digital receipts retain their balanced border. Paper-only blank rows are
        // removed by receiptPrintRaster when an outgoing job is prepared.
        nonisolated static let bottomPadding = 28
        /// Legacy header spacing, unchanged so saved custom headers print as before.
        nonisolated static let legacyTextInset = 28
        nonisolated static let legacyEventBottomPadding = 12
        nonisolated static let legacyHeaderPhotoGap = 12
    }

    nonisolated static func makeSessionIdentifier(date: Date = Date()) -> String {
        "PP-\(identifierFormatter.string(from: date))"
    }

    /// - Parameters:
    ///   - galleryURL: the session's gallery. Always pass it when it exists: whether the QR is
    ///     printed is decided only by `printOptions`.
    ///   - printOptions: the session's frozen physical-print options.
    ///   - printsSessionIdentifier: false only for operator display samples. Keep the normal
    ///     digital canvas while omitting the text; print preparation trims blank paper rows.
    nonisolated static func compose(
        photos: [UIImage],
        sessionIdentifier: String,
        date: Date = Date(),
        galleryURL: URL? = nil,
        format: BoothFormat,
        eventProfile: EventProfile? = nil,
        passport: PassportSessionData? = nil,
        photoQualityProfile: PocketPixelsThermalPhotoProfile = .customerPrintDefault,
        printOptions: ReceiptPrintOptions = .default,
        stickers: [FrozenStickerDecoration] = [],
        printsSessionIdentifier: Bool = true,
        sampleGalleryPlaceholder: Bool = false
    ) throws -> ComposedReceipt {
        try Task.checkCancellation()
        guard photos.count == format.photoCount else {
            throw ReceiptComposerError.missingPhotos(expected: format.photoCount, actual: photos.count)
        }

        let eventSnapshot = eventProfile?.activeReceiptSnapshot
        let headerArtwork = loadEffectiveHeaderArtwork(for: eventSnapshot)
        let textSnapshot = makeTextSnapshot(
            format: format,
            date: date,
            sessionIdentifier: printsSessionIdentifier ? sessionIdentifier : "",
            eventProfile: eventSnapshot,
            headerSourceSize: headerArtwork?.size,
            headerContentBounds: headerArtwork?.contentBounds
        )
        let style = printOptions.footerStyle
        let hasQRLayout = printOptions.includesPrintedGalleryQR && (galleryURL != nil || sampleGalleryPlaceholder)
        let qrDots: Int
        if let galleryURL, hasQRLayout {
            qrDots = max(receiptQRCodeSize, try GalleryQRCodeGenerator.moduleAlignedPixelSize(for: galleryURL, moduleScale: 4))
            let maximum = style == .integratedGalleryQR ? 288 : BoothConfiguration.receiptWidth - Metrics.photoMargin * 2
            guard qrDots <= maximum else {
                throw ReceiptComposerError.invalidLayout("Gallery URL requires a QR wider than the safe footer allocation.")
            }
        } else { qrDots = receiptQRCodeSize }
        let qrImage: UIImage? = try {
            guard let galleryURL, printOptions.includesPrintedGalleryQR else { return nil }
            return try GalleryQRCodeGenerator.makeQRCodeImage(for: galleryURL, pixelSize: qrDots)
        }()
        let passportContent = makePassportContent(
            format: format,
            passport: passport,
            eventProfile: eventSnapshot,
            textSnapshot: textSnapshot,
            date: date
        )
        let plan = try makeLayoutPlan(
            format: format,
            textSnapshot: textSnapshot,
            includesPrintedQR: hasQRLayout,
            footerStyle: style,
            qrDots: qrDots,
            passportContent: passportContent
        )
        try validateLayoutPlan(plan)
        try Task.checkCancellation()

        let width = BoothConfiguration.receiptWidth
        let height = plan.height

        guard height <= BoothConfiguration.receiptMaximumHeight else {
            throw ReceiptComposerError.heightExceeded(height)
        }

        let preparedPhotos = try preparePhotos(
            photos,
            for: plan,
            profile: photoQualityProfile
        )
        try Task.checkCancellation()
        let stickerLayout = makeStickerLayout(for: plan)
        var drawnStickerIDs: [UUID] = []

        let rendererFormat = UIGraphicsImageRendererFormat()
        rendererFormat.scale = 1
        rendererFormat.opaque = true

        let size = CGSize(width: width, height: height)
        let renderer = UIGraphicsImageRenderer(size: size, format: rendererFormat)
        let image = renderer.image { context in
            let cgContext = context.cgContext
            UIColor.white.setFill()
            cgContext.fill(CGRect(origin: .zero, size: size))

            if let photoPassLayout = plan.photoPassLayout, let photoPassContent = plan.photoPassContent {
                // Photo Pass sits under the same masthead (or Event-First artwork) as every format.
                drawHeader(textSnapshot: textSnapshot, layout: plan.headerLayout, customArtwork: headerArtwork)
                PhotoPassRenderer.draw(
                    content: photoPassContent,
                    layout: photoPassLayout,
                    portraitPhoto: preparedPhotos[PhotoPassReceiptLayout.portraitPhotoIndex].image,
                    heroPhoto: preparedPhotos[PhotoPassReceiptLayout.heroPhotoIndex].image,
                    context: cgContext
                )
            } else if let passportLayout = plan.passportLayout, let passportContent = plan.passportContent {
                PassportReceiptRenderer.draw(
                    content: passportContent,
                    layout: passportLayout,
                    portraitPhoto: preparedPhotos[PassportReceiptLayout.portraitPhotoIndex].image,
                    heroPhoto: preparedPhotos[PassportReceiptLayout.heroPhotoIndex].image,
                    headerGraphic: passportLayout.headerGraphicRect.flatMap { rect in
                        // Vector artwork is rendered at the card's exact dot size to stay sharp.
                        headerArtwork.map { $0.kind == .vector ? $0.image(pixelSize: rect.size) : $0.image() }
                    },
                    context: cgContext
                )
            } else {
                drawHeader(textSnapshot: textSnapshot, layout: plan.headerLayout, customArtwork: headerArtwork)

                for frame in plan.photoFrames {
                    drawPhoto(
                        preparedPhotos[frame.photoIndex].image,
                        in: frame.rect,
                        context: cgContext
                    )
                }
            }

            // Guest stickers sit on the photographs, clipped to measured safe regions, and are
            // drawn before the editorial section so the QR and its quiet zone always stay clean.
            // With no stickers nothing is drawn and the receipt is byte-for-byte unchanged.
            if !stickers.isEmpty {
                drawnStickerIDs = StickerCompositionRenderer.draw(stickers, regions: stickerLayout.regions, context: cgContext)
            }

            drawEditorial(
                layout: plan.editorialLayout,
                textSnapshot: textSnapshot,
                artwork: headerArtwork,
                qrImage: qrImage,
                context: cgContext
            )
        }

        try Task.checkCancellation()

        guard let data = image.pngData(),
              let decodedImage = UIImage(data: data),
              Int(decodedImage.size.width) == width,
              Int(decodedImage.size.height) == height,
              image.size.width == CGFloat(width),
              image.size.height == CGFloat(height) else {
            throw ReceiptComposerError.renderFailed
        }

#if DEBUG
        let headerHeight = plan.headerLayout.bottom - plan.headerLayout.startY
        debugLog("[ReceiptHeader] headerHeight=\(headerHeight) event=\(eventSnapshot != nil) branding=\(plan.branding.placement.rawValue) printedQR=\(plan.includesPrintedGalleryQR) receiptHeight=\(height) estimatedLengthMM=\(String(format: "%.1f", Double(height) / 8.0))")
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
            photoQualityProfile: photoQualityProfile,
            includesPrintedGalleryQR: qrImage != nil,
            stickerLayout: stickerLayout,
            drawnStickerPlacementIDs: drawnStickerIDs
        )
    }

    /// Sticker-safe regions measured from the exact plan that is being drawn.
    nonisolated static func makeStickerLayout(for plan: ReceiptLayoutPlan) -> StickerLayoutSnapshot {
        StickerLayoutSnapshot(
            canvasWidth: plan.width,
            canvasHeight: plan.height,
            regions: StickerGeometry.regions(
                photoFrames: plan.photoFrames,
                protectedRects: stickerProtectedRects(for: plan),
                canvasWidth: plan.width,
                canvasHeight: plan.height
            )
        )
    }

    /// Every printed element a sticker must never cover: branding, header artwork, the footer
    /// (barcode, rules, monogram, date and time), caption, event text and signature, studio credit,
    /// QR with its quiet zone and label, the session identifier and the Passport / Photo Pass
    /// cards (name, note, signature).
    nonisolated static func stickerProtectedRects(for plan: ReceiptLayoutPlan) -> [CGRect] {
        let header = plan.headerLayout
        let editorial = plan.editorialLayout
        var rects: [CGRect] = header.mastheadTexts.map(\.rect)
        rects += [header.customImageFrame, header.coBrandSeparator].compactMap { $0 }
        rects += header.eventTextFrames.map(\.rect)
        rects += editorial.footer.elementFrames
        rects += editorial.captionTexts.map(\.rect)
        rects += [editorial.signatureFrame, editorial.qrSeparator, editorial.qrLabel?.rect].compactMap { $0 }
        rects += editorial.eventTextFrames.map(\.rect)
        rects += editorial.creditTexts.map(\.rect)
        if let qrRect = editorial.qrRect {
            rects.append(qrRect.insetBy(dx: -StickerGeometry.qrQuietZoneDots, dy: -StickerGeometry.qrQuietZoneDots))
        }
        rects.append(editorial.sessionText.rect)
        if let passport = plan.passportLayout {
            rects += [passport.upperCard, passport.lowerCard]
        }
        if let photoPass = plan.photoPassLayout {
            rects += [photoPass.template.upperCardRect, photoPass.template.lowerCardRect]
        }
        return rects
    }

    nonisolated static func makeLayoutPlan(
        format: BoothFormat,
        includesGalleryQRCode: Bool = true,
        eventProfile: EventProfile? = nil,
        passport: PassportSessionData? = nil,
        date: Date = Date(timeIntervalSince1970: 1_788_692_040),
        footerStyle: ReceiptFooterStyle = .integratedGalleryQR,
        qrDots: Int = receiptQRCodeSize,
        printsSessionIdentifier: Bool = true
    ) throws -> ReceiptLayoutPlan {
        let eventSnapshot = eventProfile?.activeReceiptSnapshot
        let artwork = loadEffectiveHeaderArtwork(for: eventSnapshot)
        let textSnapshot = makeTextSnapshot(
            format: format,
            date: date,
            sessionIdentifier: printsSessionIdentifier ? "PP-20260907-161400" : "",
            eventProfile: eventSnapshot,
            headerSourceSize: artwork?.size,
            headerContentBounds: artwork?.contentBounds
        )
        let passportContent = makePassportContent(
            format: format,
            passport: passport,
            eventProfile: eventSnapshot,
            textSnapshot: textSnapshot,
            date: date
        )
        return try makeLayoutPlan(format: format, textSnapshot: textSnapshot, includesPrintedQR: includesGalleryQRCode && footerStyle != .decorativeBarcodeOnly, footerStyle: footerStyle, qrDots: qrDots, passportContent: passportContent)
    }

    /// Effective branding for the operator UI, using the same resolution as the printer.
    nonisolated static func brandingResolution(for eventProfile: EventProfile?) -> ReceiptBrandingResolution {
        let snapshot = eventProfile?.activeReceiptSnapshot
        return ReceiptBrandingResolution.resolve(
            header: snapshot?.receiptHeader,
            artworkAvailable: loadEffectiveHeaderArtwork(for: snapshot) != nil
        )
    }

    /// Resolves frozen Passport strings for the session's stored design version. A missing
    /// session value falls back to blank fields in the current design with the effective event
    /// configuration, so diagnostics and previews always render.
    nonisolated private static func makePassportContent(
        format: BoothFormat,
        passport: PassportSessionData?,
        eventProfile: EventProfile?,
        textSnapshot: ReceiptTextSnapshot,
        date: Date
    ) -> PassportDesignContent? {
        guard format == .passport else { return nil }
        let data = passport ?? PassportSessionData(configuration: PassportConfiguration.effective(for: eventProfile))
        switch data.designVersion {
        case .photoPassV2:
            return .photoPass(PhotoPassContent.resolve(passport: data, eventProfile: eventProfile, referenceDate: date))
        case .legacyPassport:
            return .legacy(PassportReceiptContent.resolve(
                passport: data,
                eventProfile: eventProfile,
                headerGraphicAvailable: textSnapshot.headerConfiguration.mode == .customEventHeader && textSnapshot.headerSourceSize != nil,
                referenceDate: date
            ))
        }
    }

    nonisolated private static func makeLayoutPlan(
        format: BoothFormat,
        textSnapshot: ReceiptTextSnapshot,
        includesPrintedQR: Bool,
        footerStyle: ReceiptFooterStyle,
        qrDots: Int,
        passportContent: PassportDesignContent? = nil
    ) throws -> ReceiptLayoutPlan {
        let width = BoothConfiguration.receiptWidth
        let branding = textSnapshot.branding
        let isLegacyPassport = passportContent?.legacyContent != nil
        // Profiles saved before branding modes never printed their header artwork on Photo Pass;
        // it keeps the Made to Keep masthead. Event-First artwork leads Photo Pass like any format.
        let showsTopArtwork = branding.showsTopArtwork && !(format == .passport && branding.placement == .legacyHeader)
        let headerLayout = makeHeaderLayout(format: format, textSnapshot: textSnapshot, isLegacyPassport: isLegacyPassport, width: width)

        let top = headerLayout.bottom
        let photoWidth = width - Metrics.photoMargin * 2
        let photoX = Metrics.photoMargin
        let gutter = Metrics.photoGutter
        let photoFrames: [ReceiptPhotoFrame]
        var passportLayout: PassportReceiptLayout?
        var photoPassLayout: PhotoPassReceiptLayout?

        switch format {
        case .solo:
            photoFrames = [ReceiptPhotoFrame(
                photoIndex: 0,
                rect: CGRect(x: photoX, y: top, width: photoWidth, height: portraitHeight(for: photoWidth))
            )]
        case .duo, .strip:
            // Landscape crops stacked with a clean white gutter (two for Duo, three for Strip).
            let photoHeight = landscapePresentationHeight(for: photoWidth)
            photoFrames = (0..<format.photoCount).map { index in
                ReceiptPhotoFrame(
                    photoIndex: index,
                    rect: CGRect(x: photoX, y: top + index * (photoHeight + gutter), width: photoWidth, height: photoHeight)
                )
            }
        case .grid, .gridSix:
            let tileWidth = (photoWidth - gutter) / 2
            let tileHeight = portraitHeight(for: tileWidth)
            let leftX = (width - (tileWidth * 2 + gutter)) / 2
            photoFrames = (0..<format.photoCount).map { index in
                ReceiptPhotoFrame(
                    photoIndex: index,
                    rect: CGRect(
                        x: leftX + (index % 2) * (tileWidth + gutter),
                        y: top + (index / 2) * (tileHeight + gutter),
                        width: tileWidth,
                        height: tileHeight
                    )
                )
            }
        case .passport:
            switch passportContent {
            case .photoPass(let content):
                let layout = PhotoPassReceiptLayout.make(content: content, top: top)
                photoPassLayout = layout
                photoFrames = layout.photoFrames
            case .legacy(let content):
                let layout = PassportReceiptLayout.make(
                    content: content,
                    headerGraphicSourceSize: textSnapshot.headerSourceSize,
                    top: top
                )
                passportLayout = layout
                photoFrames = layout.photoFrames
            case nil:
                throw ReceiptComposerError.invalidLayout("passport content is missing")
            }
        }

        let contentBottom = photoPassLayout?.bottom ?? passportLayout?.bottom ?? Int(photoFrames.map(\.rect.maxY).max() ?? CGFloat(top))
        let previewContentHeight = contentBottom + 12
        let editorial = makeEditorialLayout(
            format: format,
            contentBottom: contentBottom,
            textSnapshot: textSnapshot,
            includesPrintedQR: includesPrintedQR,
            footerStyle: footerStyle,
            qrDots: qrDots,
            isLegacyPassport: passportLayout != nil,
            width: width
        )

        let headerMode: ReceiptHeaderMode
        if isLegacyPassport || (branding.placement == .legacyHeader && format != .passport) {
            headerMode = textSnapshot.headerConfiguration.mode
        } else {
            headerMode = showsTopArtwork ? .customEventHeader : .pocketPixelsDefault
        }

        return ReceiptLayoutPlan(
            format: format,
            textSnapshot: textSnapshot,
            headerLayout: headerLayout,
            editorialLayout: editorial,
            displayedPhotoIndexes: Array(0..<format.photoCount),
            photoFrames: photoFrames,
            groupFrame: nil,
            width: width,
            height: editorial.bottom,
            previewContentHeight: previewContentHeight,
            qrSize: editorial.qrRect.map { Int($0.width) } ?? 0,
            includesPrintedGalleryQR: editorial.qrRect != nil,
            qrRect: editorial.qrRect,
            headerMode: headerMode,
            branding: branding,
            customHeaderFrame: passportLayout?.headerGraphicRect ?? headerLayout.customImageFrame,
            eventSignatureFrame: editorial.signatureFrame,
            coBrandSeparatorFrame: headerLayout.coBrandSeparator,
            mastheadFrames: headerLayout.mastheadTexts.map(\.rect),
            captionLines: editorial.captionTexts.map(\.text),
            captionFrames: editorial.captionTexts.map(\.rect),
            footer: editorial.footer,
            footerFrames: editorial.footer.elementFrames,
            studioCreditFrames: editorial.creditTexts.map(\.rect),
            sessionIdentifierFrame: editorial.sessionText.rect,
            showsEventTextBlock: textSnapshot.eventContent != nil,
            eventTextFrames: headerLayout.eventTextFrames + editorial.eventTextFrames,
            passportLayout: passportLayout,
            passportContent: passportLayout == nil ? nil : passportContent?.legacyContent,
            photoPassLayout: photoPassLayout,
            photoPassContent: photoPassLayout == nil ? nil : passportContent?.photoPassContent,
            contentBottom: contentBottom,
            footerBottom: editorial.footer.bottom
        )
    }

    // MARK: Header

    /// The one place that decides which header a receipt prints.
    nonisolated private static func makeHeaderLayout(format: BoothFormat, textSnapshot: ReceiptTextSnapshot, isLegacyPassport: Bool, width: Int) -> ReceiptHeaderLayout {
        let branding = textSnapshot.branding
        // Profiles saved before branding modes never printed their header artwork on Photo Pass;
        // it keeps the Made to Keep masthead. Event-First artwork leads Photo Pass like any format.
        let showsTopArtwork = branding.showsTopArtwork && !(format == .passport && branding.placement == .legacyHeader)
        if isLegacyPassport {
            return makeSuppressedHeaderLayout(textSnapshot: textSnapshot, startY: Metrics.receiptTopPadding)
        } else if branding.placement == .coBranded, let sourceSize = textSnapshot.headerSourceSize {
            return makeCoBrandedHeaderLayout(textSnapshot: textSnapshot, sourceSize: sourceSize, startY: Metrics.receiptTopPadding, width: width)
        } else if branding.placement == .legacyHeader && format != .passport {
            return makeLegacyHeaderLayout(textSnapshot: textSnapshot, startY: Metrics.receiptTopPadding, width: width)
        }
        return makeEditorialHeaderLayout(textSnapshot: textSnapshot, showsTopArtwork: showsTopArtwork, startY: Metrics.receiptTopPadding, width: width)
    }

    /// The header band exactly as a Solo receipt prints it (masthead, Co-Branded lockup or event
    /// artwork), for design editors. Uses the same layout and drawing as `compose`.
    nonisolated static func renderHeaderStrip(eventProfile: EventProfile?) -> (image: UIImage, artworkFrame: CGRect?) {
        let snapshot = eventProfile?.activeReceiptSnapshot
        let artwork = loadEffectiveHeaderArtwork(for: snapshot)
        let textSnapshot = makeTextSnapshot(format: .solo, date: Date(), sessionIdentifier: "", eventProfile: snapshot,
                                            headerSourceSize: artwork?.size, headerContentBounds: artwork?.contentBounds)
        let width = BoothConfiguration.receiptWidth
        let layout = makeHeaderLayout(format: .solo, textSnapshot: textSnapshot, isLegacyPassport: false, width: width)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let size = CGSize(width: width, height: max(1, layout.bottom))
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            drawHeader(textSnapshot: textSnapshot, layout: layout, customArtwork: artwork)
        }
        return (image, layout.customImageFrame)
    }

    /// The legacy Passport carries its own title and artwork inside the upper card, so no
    /// masthead or event text block is stacked above it.
    nonisolated private static func makeSuppressedHeaderLayout(textSnapshot: ReceiptTextSnapshot, startY: Int) -> ReceiptHeaderLayout {
        ReceiptHeaderLayout(
            mode: textSnapshot.headerConfiguration.mode,
            startY: startY,
            mastheadTexts: [],
            customImageFrame: nil,
            eventTextFrames: [],
            dividerY: nil,
            bottom: startY
        )
    }

    /// Studio-First, Event-First and Photo Pass: either the Made to Keep masthead or the event
    /// artwork, never both. Event details print in the supplementary area below the footer.
    nonisolated private static func makeEditorialHeaderLayout(textSnapshot: ReceiptTextSnapshot, showsTopArtwork: Bool, startY: Int, width: Int) -> ReceiptHeaderLayout {
        if showsTopArtwork, let sourceSize = textSnapshot.headerSourceSize {
            let config = textSnapshot.headerConfiguration
            let frame = EventHeaderImageProcessor.frameRect(
                sourceSize: sourceSize,
                configuration: config,
                y: CGFloat(startY + Int(config.topSpacing.rounded())),
                receiptWidth: CGFloat(width)
            )
            return ReceiptHeaderLayout(
                mode: .customEventHeader,
                startY: startY,
                mastheadTexts: [],
                customImageFrame: frame,
                eventTextFrames: [],
                dividerY: nil,
                bottom: Int(frame.maxY.rounded()) + Int(config.bottomSpacing.rounded()) + Metrics.topArtworkPhotoGap
            )
        }

        let masthead = makeMastheadTexts(
            top: startY + Metrics.mastheadTopInset,
            wordmarkStyle: .wordmark,
            wordmarkSize: Metrics.wordmarkSize,
            studiosStyle: .studios,
            studiosSize: Metrics.studiosSize,
            studiosTracking: Metrics.studiosTracking,
            gap: Metrics.wordmarkStudiosGap,
            width: width
        )
        return ReceiptHeaderLayout(
            mode: .pocketPixelsDefault,
            startY: startY,
            mastheadTexts: masthead.texts,
            customImageFrame: nil,
            eventTextFrames: [],
            dividerY: nil,
            bottom: masthead.bottom + Metrics.mastheadPhotoGap
        )
    }

    /// Co-Branded: `made to keep / studios` × event logo on one shared midline. The wordmark is
    /// sized to its half of the paper, the logo keeps its own proportions inside a box that suits
    /// both wide and square marks, and the × stays centred on the paper.
    nonisolated private static func makeCoBrandedHeaderLayout(textSnapshot: ReceiptTextSnapshot, sourceSize: CGSize, startY: Int, width: Int) -> ReceiptHeaderLayout {
        typealias Geometry = CoBrandedHeaderGeometry
        let actualConfig = textSnapshot.headerConfiguration
        var config = actualConfig
        if let adjustments = config.coBrandedAdjustments {
            config.scale = adjustments.referenceLogoScale
            config.layoutMode = adjustments.referenceLayoutMode
            config.fillHeightRatio = adjustments.referenceFillHeightRatio
        }
        let receiptWidth = CGFloat(width)
        let slot = Geometry.slotWidth(receiptWidth: receiptWidth)
        let position = config.effectiveHorizontalPosition
        let spacing = Geometry.verticalSpacing(configuration: config, mastheadTopInset: Metrics.mastheadTopInset, mastheadPhotoGap: Metrics.mastheadPhotoGap)

        // Largest wordmark that fits its slot, with `studios` kept in masthead proportion.
        var wordmarkSize = Geometry.wordmarkMaximumSize
        let wordmarkFont = font(for: .wordmark, size: wordmarkSize)
        let naturalWidth = visibleWidth(MadeToKeepBrand.wordmark, font: wordmarkFont, tracking: 0)
        if naturalWidth > slot {
            wordmarkSize = max(Geometry.wordmarkMinimumSize, floor(wordmarkSize * slot / naturalWidth * 10) / 10)
        }
        let ratio = wordmarkSize / Geometry.mastheadWordmarkSize
        let studiosSize = max(Geometry.studiosMinimumSize, (Geometry.mastheadStudiosSize * ratio * 10).rounded() / 10)
        let studiosTracking = (Geometry.mastheadStudiosTracking * ratio * 10).rounded() / 10

        // Measure at y = 0, then place the lockup and logo on one midline.
        let probeWordmark = makeTextFrame(MadeToKeepBrand.wordmark, style: .wordmark, size: wordmarkSize, tracking: 0, anchor: .leading(0), y: 0)
        let wordmarkVisible = max(0, probeWordmark.rect.width - 1)
        let probeStudios = makeTextFrame(MadeToKeepBrand.secondary, style: .studios, size: studiosSize, tracking: studiosTracking, anchor: .leading(0), y: 0)
        let studiosTop = Int(probeWordmark.rect.maxY) + Metrics.wordmarkStudiosGap
        let blockHeight = CGFloat(studiosTop) + probeStudios.rect.height

        let logoSize = Geometry.logoFrameSize(sourceSize: textSnapshot.headerContentBounds?.size ?? sourceSize, configuration: config, receiptWidth: receiptWidth)
        let bandTop = CGFloat(startY + spacing.top)
        let bandHeight = max(blockHeight, logoSize.height)
        let midline = bandTop + bandHeight / 2

        let blockTop = Int((midline - blockHeight / 2).rounded())
        let wordmarkX = Geometry.slotX(width: wordmarkVisible, leftSide: true, position: position, receiptWidth: receiptWidth)
        let wordmark = makeTextFrame(MadeToKeepBrand.wordmark, style: .wordmark, size: wordmarkSize, tracking: 0, anchor: .leading(wordmarkX), y: blockTop)
        let studios = makeTextFrame(
            MadeToKeepBrand.secondary,
            style: .studios,
            size: studiosSize,
            tracking: studiosTracking,
            anchor: .center(wordmarkX + wordmarkVisible / 2),
            y: Int(wordmark.rect.maxY) + Metrics.wordmarkStudiosGap
        )

        let logoX = Geometry.slotX(width: logoSize.width, leftSide: false, position: position, receiptWidth: receiptWidth)
        let logoFrame = CGRect(x: logoX, y: floor(midline - logoSize.height / 2), width: logoSize.width, height: logoSize.height)
        let separator = CGRect(
            x: floor(receiptWidth / 2 - Geometry.separatorSize / 2),
            y: floor(midline - Geometry.separatorSize / 2),
            width: Geometry.separatorSize,
            height: Geometry.separatorSize
        )
        if let adjustments = actualConfig.coBrandedAdjustments {
            return adjustedCoBrandedHeader(wordmark: wordmark, studios: studios, logo: logoFrame,
                separator: separator, configuration: actualConfig, adjustments: adjustments,
                sourceSize: textSnapshot.headerContentBounds?.size ?? sourceSize,
                startY: startY, bottomSpacing: spacing.bottom, receiptWidth: receiptWidth)
        }
        let contentBottom = max(studios.rect.maxY, logoFrame.maxY)
        return ReceiptHeaderLayout(
            mode: .customEventHeader,
            startY: startY,
            mastheadTexts: [wordmark, studios],
            customImageFrame: logoFrame,
            eventTextFrames: [],
            dividerY: nil,
            bottom: Int(ceil(contentBottom)) + spacing.bottom,
            coBrandSeparator: separator
        )
    }

    nonisolated private static func adjustedCoBrandedHeader(
        wordmark: ReceiptTextFrame, studios: ReceiptTextFrame, logo: CGRect, separator: CGRect,
        configuration: ReceiptHeaderConfiguration, adjustments: CoBrandedHeaderAdjustments,
        sourceSize: CGSize, startY: Int, bottomSpacing: Int, receiptWidth: CGFloat
    ) -> ReceiptHeaderLayout {
        let a = adjustments.normalized()
        let baseBlock = wordmark.rect.union(studios.rect)
        let studioScale = CGFloat(a.studioScale)
        let sharedScale = CGFloat(a.compositionScale)
        let visibleWidth = (wordmark.rect.width - 1) * studioScale
        let studioX = CoBrandedHeaderGeometry.slotX(width: visibleWidth, leftSide: true,
            position: a.studioPosition, receiptWidth: receiptWidth)
        let studioCenter = studioX + visibleWidth / 2
        let studioCenterY = baseBlock.midY + CGFloat(a.studioY)
        let eventSize = CoBrandedHeaderGeometry.logoFrameSize(sourceSize: sourceSize,
            configuration: configuration, receiptWidth: receiptWidth)
        let eventX = CoBrandedHeaderGeometry.slotX(width: eventSize.width, leftSide: false,
            position: a.eventPosition, receiptWidth: receiptWidth)
        let studioWidth = visibleWidth * sharedScale
        let eventWidth = eventSize.width * sharedScale
        let edges = CoBrandedHeaderGeometry.innerEdges(receiptWidth: receiptWidth)
        // Each identity owns its final clamp. Editing one never changes the other, even
        // after the operator has translated the pair to a printable boundary.
        let studioDX = min(edges.left - (studioCenter + studioWidth / 2),
            max(CoBrandedHeaderGeometry.sideInset - (studioCenter - studioWidth / 2), CGFloat(a.studioOffsetX)))
        let eventDX = min(receiptWidth - CoBrandedHeaderGeometry.sideInset - (eventX + eventSize.width / 2 + eventWidth / 2),
            max(edges.right - (eventX + eventSize.width / 2 - eventWidth / 2), CGFloat(a.eventOffsetX)))
        let textScale = studioScale * sharedScale
        let studioHeight = baseBlock.height * textScale
        let eventHeight = eventSize.height * sharedScale
        let eventCenterY = logo.midY + CGFloat(a.eventY)
        let safeStudioY = max(CGFloat(startY + 8) + studioHeight / 2, studioCenterY)
        let safeEventY = max(CGFloat(startY + 8) + eventHeight / 2, eventCenterY)
        func text(_ frame: ReceiptTextFrame) -> ReceiptTextFrame {
            let rect = CGRect(x: studioCenter + studioDX + (frame.rect.minX - (wordmark.rect.minX + (wordmark.rect.width - 1) / 2)) * textScale,
                y: safeStudioY + (frame.rect.minY - baseBlock.midY) * textScale,
                width: frame.rect.width * textScale, height: frame.rect.height * textScale)
            return ReceiptTextFrame(style: frame.style, text: frame.text, rect: rect,
                fontSize: frame.fontSize * textScale, tracking: frame.tracking * textScale)
        }
        let texts = [text(wordmark), text(studios)]
        let eventFrame = CGRect(x: eventX + eventSize.width / 2 - eventWidth / 2 + eventDX,
            y: safeEventY - eventHeight / 2, width: eventWidth, height: eventHeight)
        let cross = separator.offsetBy(dx: 0, dy: max(CGFloat(startY + 8) - separator.minY, CGFloat(a.separatorY)))
        let bottom = max(texts.map(\.rect.maxY).max() ?? 0, eventFrame.maxY, cross.maxY)
        return ReceiptHeaderLayout(mode: .customEventHeader, startY: startY, mastheadTexts: texts,
            customImageFrame: eventFrame, eventTextFrames: [], dividerY: nil,
            bottom: Int(ceil(bottom)) + bottomSpacing, coBrandSeparator: cross)
    }

    nonisolated static func translateCoBrandedHeader(_ configuration: ReceiptHeaderConfiguration,
        horizontal: Double = 0, vertical: Double = 0) -> ReceiptHeaderConfiguration {
        var config = configuration.normalized()
        config.editCoBranded { _ in }
        var profile = EventProfile.pocketPixelsDefault
        profile.isEnabled = true; profile.showEventTextBlock = false
        profile.receiptHeader = config
        guard let current = try? makeLayoutPlan(format: .solo, eventProfile: profile),
              let logo = current.customHeaderFrame, let wordmark = current.mastheadFrames.first,
              let separator = current.coBrandSeparatorFrame,
              var a = config.coBrandedAdjustments else { return configuration }
        var baseline = config
        baseline.editCoBranded { $0.studioOffsetX = 0; $0.eventOffsetX = 0; $0.studioY = 0; $0.eventY = 0; $0.separatorY = 0 }
        profile.receiptHeader = baseline
        guard let base = try? makeLayoutPlan(format: .solo, eventProfile: profile),
              let baseLogo = base.customHeaderFrame, let baseWordmark = base.mastheadFrames.first,
              let baseSeparator = base.coBrandSeparatorFrame else { return configuration }
        let studioOffset = wordmark.minX - baseWordmark.minX
        let eventOffset = logo.minX - baseLogo.minX
        let studioY = wordmark.minY - baseWordmark.minY
        let eventY = logo.minY - baseLogo.minY
        let separatorY = separator.minY - baseSeparator.minY
        let edges = CoBrandedHeaderGeometry.innerEdges()
        let studioRight = wordmark.maxX - CGFloat(a.studioScale * a.compositionScale)
        let lowerX = max(CoBrandedHeaderGeometry.sideInset - wordmark.minX, edges.right - logo.minX,
            -48 - studioOffset, -48 - eventOffset)
        let upperX = min(edges.left - studioRight, CGFloat(BoothConfiguration.receiptWidth) - CoBrandedHeaderGeometry.sideInset - logo.maxX, 48 - studioOffset, 48 - eventOffset)
        let dx = min(upperX, max(lowerX, CGFloat(horizontal.isFinite ? horizontal : 0)))
        let top = CGFloat(Metrics.receiptTopPadding + 8)
        let lowerY = max(top - min(wordmark.minY, logo.minY, separator.minY),
            -48 - studioY, -48 - eventY, -48 - separatorY)
        let upperY = min(48 - studioY, 48 - eventY, 48 - separatorY)
        let dy = min(upperY, max(lowerY, CGFloat(vertical.isFinite ? vertical : 0)))
        a.studioOffsetX = Double(studioOffset + dx); a.eventOffsetX = Double(eventOffset + dx)
        a.studioY = Double(studioY + dy); a.eventY = Double(eventY + dy); a.separatorY = Double(separatorY + dy)
        config.coBrandedAdjustments = a.normalized()
        return config
    }

    /// Profiles saved before branding modes keep their header exactly where it was: the saved
    /// header (Made to Keep masthead, custom artwork or none), event details, then a divider.
    nonisolated private static func makeLegacyHeaderLayout(textSnapshot: ReceiptTextSnapshot, startY: Int, width: Int) -> ReceiptHeaderLayout {
        var y = startY
        var mastheadTexts: [ReceiptTextFrame] = []
        var customImageFrame: CGRect?
        let mode = textSnapshot.headerConfiguration.mode

        switch mode {
        case .pocketPixelsDefault:
            let masthead = makeMastheadTexts(
                top: y + Metrics.mastheadTopInset,
                wordmarkStyle: .wordmark,
                wordmarkSize: Metrics.wordmarkSize,
                studiosStyle: .studios,
                studiosSize: Metrics.studiosSize,
                studiosTracking: Metrics.studiosTracking,
                gap: Metrics.wordmarkStudiosGap,
                width: width
            )
            mastheadTexts = masthead.texts
            y = masthead.bottom + Metrics.legacyEventBottomPadding
        case .customEventHeader:
            let config = textSnapshot.headerConfiguration
            y += Int(config.topSpacing.rounded())
            let frame = EventHeaderImageProcessor.frameRect(
                sourceSize: textSnapshot.headerSourceSize ?? .zero,
                configuration: config,
                y: CGFloat(y),
                receiptWidth: CGFloat(width)
            )
            customImageFrame = frame
            y += Int(frame.height.rounded()) + Int(config.bottomSpacing.rounded())
        case .none:
            y += 6
        }

        var eventTextFrames: [EventTextBlockFrame] = []
        if let content = textSnapshot.eventContent {
            let textX = BoothConfiguration.receiptHorizontalMargin + Metrics.legacyTextInset
            let block = EventTextBlockLayout.make(
                content: content,
                typography: textSnapshot.eventTypography,
                x: textX,
                y: y,
                width: width - textX * 2
            )
            eventTextFrames = block.frames
            y = block.bottom + Metrics.legacyEventBottomPadding
        }

        // A plain masthead flows straight into the photographs like the editorial receipt;
        // artwork, a hidden header or event details keep the legacy divider.
        if mode == .pocketPixelsDefault && eventTextFrames.isEmpty {
            return ReceiptHeaderLayout(
                mode: mode,
                startY: startY,
                mastheadTexts: mastheadTexts,
                customImageFrame: nil,
                eventTextFrames: [],
                dividerY: nil,
                bottom: y - Metrics.legacyEventBottomPadding + Metrics.mastheadPhotoGap
            )
        }
        return ReceiptHeaderLayout(
            mode: mode,
            startY: startY,
            mastheadTexts: mastheadTexts,
            customImageFrame: customImageFrame,
            eventTextFrames: eventTextFrames,
            dividerY: y,
            bottom: y + 1 + Metrics.legacyHeaderPhotoGap
        )
    }

    /// `made to keep` over widely tracked `studios`, centered on the paper.
    nonisolated private static func makeMastheadTexts(
        top: Int,
        wordmarkStyle: ReceiptTextStyle,
        wordmarkSize: CGFloat,
        studiosStyle: ReceiptTextStyle,
        studiosSize: CGFloat,
        studiosTracking: CGFloat,
        gap: Int,
        width: Int
    ) -> (texts: [ReceiptTextFrame], bottom: Int) {
        let center = CGFloat(width) / 2
        let wordmark = makeTextFrame(MadeToKeepBrand.wordmark, style: wordmarkStyle, size: wordmarkSize, tracking: 0, anchor: .center(center), y: top)
        let studios = makeTextFrame(
            MadeToKeepBrand.secondary,
            style: studiosStyle,
            size: studiosSize,
            tracking: studiosTracking,
            anchor: .center(center),
            y: Int(wordmark.rect.maxY) + gap
        )
        return ([wordmark, studios], Int(ceil(studios.rect.maxY)))
    }

    // MARK: Editorial section

    nonisolated private static func makeEditorialLayout(
        format: BoothFormat,
        contentBottom: Int,
        textSnapshot: ReceiptTextSnapshot,
        includesPrintedQR: Bool,
        footerStyle: ReceiptFooterStyle,
        qrDots: Int,
        isLegacyPassport: Bool,
        width: Int
    ) -> ReceiptEditorialLayout {
        let center = CGFloat(width) / 2

        // A. The reference footer, clear of the photographs.
        let integrated = includesPrintedQR && footerStyle == .integratedGalleryQR
        let footer = integrated
            ? makeIntegratedFooterLayout(top: contentBottom + Metrics.photoFooterGap, dateLines: textSnapshot.footerDateLines, width: width, qrDots: qrDots)
            : makeFooterLayout(top: contentBottom + Metrics.photoFooterGap, dateLines: textSnapshot.footerDateLines, width: width)
        var y = footer.bottom

        // B. Supplementary area: event caption, event signature, event details, studio credit.
        let branding = textSnapshot.branding
        var hasSecondaryContent = false
        func advanceSecondary() {
            y += hasSecondaryContent ? Metrics.secondaryInnerGap : Metrics.secondaryGap
            hasSecondaryContent = true
        }

        var captionTexts: [ReceiptTextFrame] = []
        if !textSnapshot.captionLines.isEmpty {
            advanceSecondary()
            let size = fittedCaptionSize(textSnapshot.captionLines, maximumWidth: Metrics.captionMaximumWidth)
            for (index, line) in textSnapshot.captionLines.enumerated() {
                if index > 0 { y += Metrics.captionLineGap }
                let frame = makeTextFrame(line, style: .caption, size: size, tracking: Metrics.captionTracking, anchor: .center(center), y: y)
                captionTexts.append(frame)
                y = Int(ceil(frame.rect.maxY))
            }
        }

        var signatureFrame: CGRect?
        // The legacy Passport already prints the artwork inside its card.
        if !isLegacyPassport, branding.showsArtworkSignature, let sourceSize = textSnapshot.headerSourceSize {
            advanceSecondary()
            let frame = EventHeaderImageProcessor.signatureFrameRect(
                sourceSize: sourceSize,
                configuration: textSnapshot.headerConfiguration,
                y: CGFloat(y),
                receiptWidth: CGFloat(width)
            )
            signatureFrame = frame
            y = Int(ceil(frame.maxY))
        }

        var eventTextFrames: [EventTextBlockFrame] = []
        // Photo Pass prints the event inside its own fields.
        if format != .passport, branding.showsEventDetailsBelowFooter, let content = textSnapshot.eventContent {
            advanceSecondary()
            let block = EventTextBlockLayout.make(
                content: content,
                typography: textSnapshot.eventTypography,
                x: Metrics.eventTextInset,
                y: y,
                width: width - Metrics.eventTextInset * 2
            )
            eventTextFrames = block.frames
            y = block.bottom
        }

        var creditTexts: [ReceiptTextFrame] = []
        // Only the operator's Event-First credit option: the footer monogram already signs every
        // receipt, including Photo Pass and the legacy Passport.
        if branding.showsStudioCredit {
            advanceSecondary()
            let credit = makeMastheadTexts(
                top: y,
                wordmarkStyle: .creditWordmark,
                wordmarkSize: Metrics.creditWordmarkSize,
                studiosStyle: .creditStudios,
                studiosSize: Metrics.creditStudiosSize,
                studiosTracking: Metrics.creditStudiosTracking,
                gap: Metrics.creditStudiosGap,
                width: width
            )
            creditTexts = credit.texts
            y = credit.bottom
        }

        // C. Optional gallery QR, separated from the keepsake by a dashed tear line.
        var qrSeparator: CGRect?
        var qrRect: CGRect? = footer.integratedQRFrame
        var qrLabel: ReceiptTextFrame? = footer.integratedQRLabel
        if includesPrintedQR && !integrated {
            y += Metrics.qrSectionGap
            let separator = CGRect(x: CGFloat(Metrics.photoMargin), y: CGFloat(y), width: CGFloat(width - Metrics.photoMargin * 2), height: CGFloat(Metrics.qrSeparatorThickness))
            qrSeparator = separator
            y += Metrics.qrSeparatorThickness + Metrics.qrSeparatorGap
            let rect = CGRect(x: (width - qrDots) / 2, y: y, width: qrDots, height: qrDots)
            qrRect = rect
            y += qrDots + Metrics.qrLabelGap
            let label = makeTextFrame(textSnapshot.qrLabel, style: .qrLabel, size: Metrics.qrLabelSize, tracking: Metrics.qrLabelTracking, anchor: .center(center), y: y)
            qrLabel = label
            y = Int(ceil(label.rect.maxY))
        }

        // D. Keep normal digital spacing for previews, gallery and Photos exports.
        // Samples leave the identifier blank; only the outgoing paper raster is shortened.
        y += Metrics.sessionGap
        let sessionText = makeTextFrame(textSnapshot.sessionIdentifier, style: .sessionIdentifier, size: Metrics.sessionSize, tracking: Metrics.sessionTracking, anchor: .center(center), y: y)
        y = Int(ceil(sessionText.rect.maxY)) + Metrics.bottomPadding

        return ReceiptEditorialLayout(
            footer: footer,
            captionTexts: captionTexts,
            signatureFrame: signatureFrame,
            eventTextFrames: eventTextFrames,
            creditTexts: creditTexts,
            qrSeparator: qrSeparator,
            qrRect: qrRect,
            qrLabel: qrLabel,
            sessionText: sessionText,
            bottom: y
        )
    }

    /// Barcode | monogram | date and time. The monogram is the tallest element; the barcode,
    /// rules and the two date lines share one row centred on it.
    nonisolated private static func makeFooterLayout(top: Int, dateLines: [String], width: Int) -> ReceiptFooterLayout {
        let center = width / 2
        let rowTop = top + (Metrics.footerMonogramHeight - Metrics.footerRowHeight) / 2
        let rowHeight = Metrics.footerRowHeight

        let barcodeX = Metrics.footerSideInset
        let barcodeFrame = CGRect(x: barcodeX, y: rowTop, width: ReceiptDecorativeBarcode.totalWidth, height: rowHeight)
        let barcodeBars = ReceiptDecorativeBarcode.bars(originX: barcodeX, y: rowTop, height: rowHeight)

        let separatorFrames = [-1, 1].map { side in
            CGRect(
                x: center + side * Metrics.footerSeparatorOffset - Metrics.footerSeparatorWidth / 2,
                y: rowTop,
                width: Metrics.footerSeparatorWidth,
                height: rowHeight
            )
        }

        let monogramWidth = Int((CGFloat(Metrics.footerMonogramHeight) * ReceiptMonogramArtwork.aspectRatio).rounded())
        let monogramFrame = CGRect(x: center - monogramWidth / 2, y: top, width: monogramWidth, height: Metrics.footerMonogramHeight)

        // Date over time, right-aligned with the photographs, vertically centred in the row.
        let font = font(for: .footer, size: Metrics.footerDateSize)
        let lineHeight = Int(ceil(font.lineHeight))
        let blockHeight = dateLines.count * lineHeight + max(0, dateLines.count - 1) * Metrics.footerDateLineGap
        var lineY = rowTop + (rowHeight - blockHeight) / 2
        let rightX = CGFloat(width - Metrics.footerSideInset)
        let dateTexts = dateLines.map { line -> ReceiptTextFrame in
            defer { lineY += lineHeight + Metrics.footerDateLineGap }
            return makeTextFrame(line, style: .footer, size: Metrics.footerDateSize, tracking: Metrics.footerDateTracking, anchor: .trailing(rightX), y: lineY)
        }

        return ReceiptFooterLayout(
            barcodeFrame: barcodeFrame,
            barcodeBars: barcodeBars,
            separatorFrames: separatorFrames,
            monogramFrame: monogramFrame,
            dateTexts: dateTexts,
            top: top,
            bottom: top + Metrics.footerMonogramHeight
        )
    }

    /// A full production URL cannot fit the old barcode column at four printer dots per
    /// module. Keep its quiet zone intact and stack the studio signature beside it.
    nonisolated private static func makeIntegratedFooterLayout(top: Int, dateLines: [String], width: Int, qrDots: Int) -> ReceiptFooterLayout {
        let left = Metrics.photoMargin
        let qr = CGRect(x: left, y: top, width: qrDots, height: qrDots)
        let label = makeTextFrame("scan for gallery", style: .qrLabel, size: 12, tracking: 1, anchor: .center(qr.midX), y: top + qrDots + 4)
        let dividerX = left + qrDots + 16
        let rightCenter = CGFloat(dividerX + width - Metrics.photoMargin) / 2
        let monogramHeight = 92
        let monogramWidth = Int((CGFloat(monogramHeight) * ReceiptMonogramArtwork.aspectRatio).rounded())
        let monogram = CGRect(x: Int(rightCenter) - monogramWidth / 2, y: top + 12, width: monogramWidth, height: monogramHeight)
        let texts = dateLines.enumerated().map { index, line in
            makeTextFrame(line, style: .footer, size: 14, tracking: 1.5, anchor: .center(rightCenter), y: top + 128 + index * 26)
        }
        return ReceiptFooterLayout(integratedQRFrame: qr, integratedQRLabel: label,
            barcodeFrame: .zero, barcodeBars: [],
            separatorFrames: [CGRect(x: dividerX, y: top + 20, width: 1, height: qrDots - 40)],
            monogramFrame: monogram, dateTexts: texts, top: top, bottom: Int(ceil(label.rect.maxY)))
    }

    /// Largest caption size at which every line fits the supplementary measure.
    nonisolated private static func fittedCaptionSize(_ lines: [String], maximumWidth: CGFloat) -> CGFloat {
        for size in Metrics.captionSizes {
            let font = font(for: .caption, size: size)
            let fits = lines.allSatisfy { visibleWidth($0, font: font, tracking: Metrics.captionTracking) <= maximumWidth }
            if fits { return size }
        }
        return Metrics.captionSizes.last ?? 13
    }

    // MARK: Text snapshot

    nonisolated private static func makeTextSnapshot(
        format: BoothFormat,
        date: Date,
        sessionIdentifier: String,
        eventProfile: EventProfile?,
        headerSourceSize: CGSize? = nil,
        headerContentBounds: CGRect? = nil
    ) -> ReceiptTextSnapshot {
        let branding = ReceiptBrandingResolution.resolve(header: eventProfile?.receiptHeader, artworkAvailable: headerSourceSize != nil)
        var configuration = eventProfile?.receiptHeader.normalized() ?? .default
        if configuration.mode == .customEventHeader, headerSourceSize == nil {
            configuration.mode = .pocketPixelsDefault
            debugLog("[ReceiptHeader] Missing custom asset; using the Made to Keep default header.")
        }

        let captionLines = ReceiptEditorialCaption.resolvedLines(
            for: format,
            eventCaption: eventProfile?.receiptDesign.editorialCaption
        )
        // The same event message never prints twice: a caption that repeats it replaces it.
        var eventContent = eventProfile?.receiptBlockContent
        if let content = eventContent,
           !content.message.isEmpty,
           content.message.uppercased() == captionLines.joined(separator: " ") {
            eventContent = EventReceiptBlockContent(
                eyebrow: content.eyebrow,
                eventName: content.eventName,
                subtitle: content.subtitle,
                metadata: content.metadata,
                message: ""
            )
        }

        return ReceiptTextSnapshot(
            eventContent: eventContent,
            eventTypography: eventProfile?.receiptDesign.typography.resolved ?? .preset(.classic),
            headerConfiguration: configuration,
            headerSourceSize: headerSourceSize,
            headerContentBounds: headerContentBounds,
            branding: branding,
            captionLines: captionLines,
            footerDateLines: [
                footerDateFormatter.string(from: date).uppercased(),
                footerTimeFormatter.string(from: date).uppercased()
            ],
            sessionIdentifier: sessionIdentifier,
            qrLabel: printedQRLabel
        )
    }

    nonisolated private static func loadEffectiveHeaderArtwork(for eventProfile: EventProfile?) -> EventArtwork? {
        guard let eventProfile,
              eventProfile.receiptHeader.mode == .customEventHeader,
              let store = try? EventHeaderAssetStore() else { return nil }
        return store.loadArtwork(identifier: eventProfile.receiptHeader.assetIdentifier)
    }

    // MARK: Validation

    nonisolated private static func validateLayoutPlan(_ plan: ReceiptLayoutPlan) throws {
        guard plan.width == BoothConfiguration.receiptWidth else {
            throw ReceiptComposerError.invalidLayout("canvas width \(plan.width) does not equal \(BoothConfiguration.receiptWidth)")
        }
        guard plan.width > 0,
              plan.height > 0,
              plan.height <= BoothConfiguration.receiptMaximumHeight,
              plan.previewContentHeight > 0 else {
            throw ReceiptComposerError.invalidLayout("canvas dimensions are outside supported bounds")
        }

        let canvas = CGRect(x: 0, y: 0, width: plan.width, height: plan.height)
        let header = plan.headerLayout
        for text in header.mastheadTexts {
            try validateFrame(text.rect, name: "header.\(text.style.rawValue)", inside: canvas)
        }
        if let customImageFrame = header.customImageFrame {
            try validateFrame(customImageFrame, name: "header.customImage", inside: canvas)
            guard customImageFrame.height <= EventHeaderImageProcessor.maximumPrintedHeight else {
                throw ReceiptComposerError.invalidLayout("custom header exceeds its safe maximum height")
            }
        }
        if let separator = header.coBrandSeparator {
            try validateCoBrandedHeader(header, separator: separator, canvas: canvas)
        }
        try validateEventText(header.eventTextFrames, name: "header.event", inside: canvas)
        for frame in header.eventTextFrames {
            if let customImageFrame = header.customImageFrame, frame.rect.intersects(customImageFrame) {
                throw ReceiptComposerError.invalidLayout("event text overlaps the header artwork")
            }
        }
        if let lastEventFrame = header.eventTextFrames.last, let dividerY = header.dividerY, Int(ceil(lastEventFrame.rect.maxY)) > dividerY {
            throw ReceiptComposerError.invalidLayout("event text extends past the header divider")
        }
        let headerContentBottom = ([header.customImageFrame, header.coBrandSeparator].compactMap { $0 } + header.mastheadTexts.map(\.rect) + header.eventTextFrames.map(\.rect))
            .map(\.maxY).max() ?? CGFloat(header.startY)
        guard headerContentBottom <= CGFloat(header.bottom),
              header.bottom <= Int(plan.photoFrames.map(\.rect.minY).min() ?? CGFloat(plan.height)) else {
            throw ReceiptComposerError.invalidLayout("header overlaps photo section")
        }

        guard plan.displayedPhotoIndexes == Array(0..<plan.format.photoCount),
              plan.photoFrames.count == plan.format.photoCount else {
            throw ReceiptComposerError.invalidLayout("photo count/index plan does not match \(plan.format.rawValue)")
        }

        let contentLeft = CGFloat(BoothConfiguration.receiptHorizontalMargin)
        let contentRight = CGFloat(plan.width - BoothConfiguration.receiptHorizontalMargin)
        var previousFrame: CGRect?
        for frame in plan.photoFrames.sorted(by: { $0.photoIndex < $1.photoIndex }) {
            try validateFrame(frame.rect, name: "photo.\(frame.photoIndex)", inside: canvas)
            guard frame.rect.width > 0,
                  frame.rect.height > 0,
                  frame.rect.minX >= contentLeft,
                  frame.rect.maxX <= contentRight else {
                throw ReceiptComposerError.invalidLayout("photo \(frame.photoIndex) outside content bounds")
            }
            if let previousFrame, previousFrame.intersects(frame.rect) {
                throw ReceiptComposerError.invalidLayout("photo frames overlap")
            }
            previousFrame = frame.rect
        }

        let photoBottom = plan.contentBottom
        guard photoBottom >= Int(plan.photoFrames.map(\.rect.maxY).max() ?? 0) else {
            throw ReceiptComposerError.invalidLayout("content section ends above a photo")
        }
        if let passportLayout = plan.passportLayout {
            try validatePassportLayout(passportLayout, contentBottom: photoBottom, canvas: canvas)
        }
        if let photoPassLayout = plan.photoPassLayout {
            try validatePhotoPassLayout(photoPassLayout, contentBottom: photoBottom, canvas: canvas)
        }
        try validateEditorialLayout(plan.editorialLayout, contentBottom: photoBottom, height: plan.height, canvas: canvas)
    }

    /// The wordmark sits left of the ×, the logo right of it, nothing touches, everything stays
    /// inside the printable width and the × is centred on the paper.
    nonisolated private static func validateCoBrandedHeader(_ header: ReceiptHeaderLayout, separator: CGRect, canvas: CGRect) throws {
        try validateFrame(separator, name: "header.coBrandSeparator", inside: canvas)
        guard let logo = header.customImageFrame, header.mastheadTexts.count == 2 else {
            throw ReceiptComposerError.invalidLayout("co-branded header is missing an identity")
        }
        let printableLeft = CGFloat(BoothConfiguration.receiptHorizontalMargin)
        let printableRight = canvas.width - CGFloat(BoothConfiguration.receiptHorizontalMargin)
        let wordmarkRight = header.mastheadTexts.map { $0.rect.maxX - $0.tracking - 1 }.max() ?? canvas.maxX
        guard abs(separator.midX - canvas.midX) <= 1,
              header.mastheadTexts.allSatisfy({ $0.rect.minX >= printableLeft }),
              wordmarkRight <= separator.minX,
              logo.minX >= separator.maxX,
              logo.maxX <= printableRight,
              logo.width > 0, logo.height > 0 else {
            throw ReceiptComposerError.invalidLayout("co-branded identities overlap the × or leave the printable width")
        }
    }

    /// Every editorial block sits inside the paper and strictly below the previous one, the
    /// footer columns stay apart and inside the printable width, and the QR section only exists
    /// when it is printed.
    nonisolated private static func validateEditorialLayout(_ layout: ReceiptEditorialLayout, contentBottom: Int, height: Int, canvas: CGRect) throws {
        try validateFooterLayout(layout.footer, contentBottom: contentBottom, canvas: canvas)
        var blocks: [(String, CGRect)] = []
        blocks.append(("footer", CGRect(x: 0, y: layout.footer.top, width: Int(canvas.width), height: layout.footer.bottom - layout.footer.top)))
        blocks.append(contentsOf: layout.captionTexts.map { ("caption.line", $0.rect) })
        if let signatureFrame = layout.signatureFrame {
            guard signatureFrame.height <= EventHeaderImageProcessor.signatureMaximumHeight,
                  signatureFrame.width <= EventHeaderImageProcessor.signatureMaximumWidth else {
                throw ReceiptComposerError.invalidLayout("event signature exceeds its compact size")
            }
            blocks.append(("signature", signatureFrame))
        }
        try validateEventText(layout.eventTextFrames, name: "secondary.event", inside: canvas)
        blocks.append(contentsOf: layout.eventTextFrames.map { ("secondary.event.\($0.role.rawValue)", $0.rect) })
        blocks.append(contentsOf: layout.creditTexts.map { ("credit.\($0.style.rawValue)", $0.rect) })
        if let qrSeparator = layout.qrSeparator { blocks.append(("qr.separator", qrSeparator)) }
        if layout.footer.integratedQRFrame == nil, let qrRect = layout.qrRect { blocks.append(("qr", qrRect)) }
        if layout.footer.integratedQRFrame == nil, let qrLabel = layout.qrLabel { blocks.append(("qr.label", qrLabel.rect)) }
        blocks.append(("session", layout.sessionText.rect))

        var previousBottom = CGFloat(contentBottom)
        for (name, rect) in blocks {
            try validateFrame(rect, name: name, inside: canvas)
            guard rect.minY >= previousBottom else {
                throw ReceiptComposerError.invalidLayout("\(name) overlaps the section above it")
            }
            previousBottom = rect.maxY
        }
        for text in layout.captionTexts + layout.footer.dateTexts + layout.creditTexts + [layout.qrLabel, layout.sessionText].compactMap({ $0 }) {
            let visibleRight = text.rect.maxX - text.tracking
            guard text.rect.minX >= CGFloat(BoothConfiguration.receiptHorizontalMargin),
                  visibleRight <= CGFloat(BoothConfiguration.receiptWidth - BoothConfiguration.receiptHorizontalMargin) else {
                throw ReceiptComposerError.invalidLayout("\(text.style.rawValue) text leaves the printable width")
            }
        }
        guard (layout.qrRect == nil) == (layout.qrSeparator == nil && layout.footer.integratedQRFrame == nil),
              (layout.qrRect == nil) == (layout.qrLabel == nil),
              layout.qrRect.map({ Int($0.width) >= receiptQRCodeSize && $0.height == $0.width }) ?? true,
              Int(ceil(previousBottom)) + Metrics.bottomPadding <= height,
              layout.bottom == height else {
            throw ReceiptComposerError.invalidLayout("editorial section dimensions do not match the plan")
        }
    }

    /// Barcode, rule, monogram, rule and date read left to right with clear space between each,
    /// the monogram is centred on the paper, and everything stays inside the footer band.
    nonisolated private static func validateFooterLayout(_ footer: ReceiptFooterLayout, contentBottom: Int, canvas: CGRect) throws {
        guard footer.top > contentBottom, footer.separatorFrames.count == (footer.integratedQRFrame == nil ? 2 : 1), !footer.dateTexts.isEmpty else {
            throw ReceiptComposerError.invalidLayout("footer is missing elements or overlaps the photographs")
        }
        let band = CGRect(x: CGFloat(BoothConfiguration.receiptHorizontalMargin), y: CGFloat(footer.top),
                          width: canvas.width - CGFloat(BoothConfiguration.receiptHorizontalMargin * 2), height: CGFloat(footer.bottom - footer.top))
        for (index, frame) in footer.elementFrames.enumerated() {
            try validateFrame(frame, name: "footer.\(index)", inside: canvas)
            guard band.contains(frame) else {
                throw ReceiptComposerError.invalidLayout("footer element \(index) leaves the footer band or printable width")
            }
        }
        guard footer.barcodeBars.allSatisfy({ footer.barcodeFrame.contains($0) }) else {
            throw ReceiptComposerError.invalidLayout("decorative barcode leaves its column")
        }
        if footer.integratedQRFrame != nil {
            for (index, frame) in footer.elementFrames.enumerated() {
                for other in footer.elementFrames.dropFirst(index + 1) where frame.intersects(other) {
                    throw ReceiptComposerError.invalidLayout("Integrated footer elements overlap")
                }
            }
            return
        }
        let dateMinX = footer.dateTexts.map(\.rect.minX).min() ?? canvas.maxX
        let clearance = CGFloat(Metrics.footerColumnClearance)
        guard footer.barcodeFrame.maxX + clearance <= footer.separatorFrames[0].minX,
              footer.separatorFrames[0].maxX + clearance <= footer.monogramFrame.minX,
              footer.monogramFrame.maxX + clearance <= footer.separatorFrames[1].minX,
              footer.separatorFrames[1].maxX + clearance <= dateMinX,
              abs(footer.monogramFrame.midX - canvas.midX) <= 1 else {
            throw ReceiptComposerError.invalidLayout("footer columns are crowded or off-centre")
        }
    }

    nonisolated private static func validateEventText(_ frames: [EventTextBlockFrame], name: String, inside canvas: CGRect) throws {
        var previousEventFrame: CGRect?
        for frame in frames {
            try validateFrame(frame.rect, name: "\(name).\(frame.role.rawValue)", inside: canvas)
            guard frame.rect.width > 0, frame.rect.height > 0, frame.fontSize.isFinite, frame.fontSize > 0 else {
                throw ReceiptComposerError.invalidLayout("event \(frame.role.rawValue) text has no usable size")
            }
            if let previousEventFrame, frame.rect.minY < previousEventFrame.maxY {
                throw ReceiptComposerError.invalidLayout("event text sections overlap")
            }
            previousEventFrame = frame.rect
        }
    }

    nonisolated private static func validatePassportLayout(_ layout: PassportReceiptLayout, contentBottom: Int, canvas: CGRect) throws {
        let contentLeft = CGFloat(BoothConfiguration.receiptHorizontalMargin)
        let contentRight = CGFloat(BoothConfiguration.receiptWidth - BoothConfiguration.receiptHorizontalMargin)
        for (name, card) in [("passport.upperCard", layout.upperCard), ("passport.lowerCard", layout.lowerCard)] {
            try validateFrame(card, name: name, inside: canvas)
            guard card.minX >= contentLeft, card.maxX <= contentRight, card.width > card.height else {
                throw ReceiptComposerError.invalidLayout("\(name) must be a landscape card inside the content margins")
            }
        }
        guard layout.upperCard.maxY <= layout.lowerCard.minY,
              layout.lowerCard.maxY <= CGFloat(contentBottom),
              layout.bottom == contentBottom,
              layout.upperCard.contains(layout.heroPhotoRect),
              layout.lowerCard.contains(layout.portraitPhotoRect),
              layout.lowerCard.contains(layout.signatureBox),
              !layout.heroPhotoRect.intersects(layout.titleColumn) else {
            throw ReceiptComposerError.invalidLayout("passport cards overlap or contain misplaced elements")
        }
        for block in layout.upperTexts where !layout.upperCard.contains(block.rect) || block.rect.intersects(layout.heroPhotoRect) {
            throw ReceiptComposerError.invalidLayout("passport upper text \(block.role) leaves its card")
        }
        for block in layout.lowerTexts where !layout.lowerCard.contains(block.rect) || block.rect.intersects(layout.portraitPhotoRect) {
            throw ReceiptComposerError.invalidLayout("passport lower text \(block.role) leaves its card")
        }
        for rect in [layout.headerGraphicRect, layout.stampRect, layout.starBandRect].compactMap({ $0 }) where !layout.titleColumn.contains(rect) {
            throw ReceiptComposerError.invalidLayout("passport decoration leaves the title column")
        }
        if let message = layout.message {
            guard message.rect.minY >= layout.lowerCard.maxY, message.rect.maxY <= CGFloat(contentBottom) else {
                throw ReceiptComposerError.invalidLayout("passport message overlaps the cards")
            }
        }
    }

    nonisolated private static func validatePhotoPassLayout(_ layout: PhotoPassReceiptLayout, contentBottom: Int, canvas: CGRect) throws {
        let template = layout.template
        let contentLeft = CGFloat(BoothConfiguration.receiptHorizontalMargin)
        let contentRight = CGFloat(BoothConfiguration.receiptWidth - BoothConfiguration.receiptHorizontalMargin)
        for (name, card) in [("photoPass.upperCard", template.upperCardRect), ("photoPass.lowerCard", template.lowerCardRect)] {
            try validateFrame(card, name: name, inside: canvas)
            guard card.minX >= contentLeft, card.maxX <= contentRight, card.width > card.height else {
                throw ReceiptComposerError.invalidLayout("\(name) must be a landscape card inside the content margins")
            }
        }
        let upper = template.contentRects[0]
        let lower = template.contentRects[1]
        guard template.upperCardRect.maxY <= template.lowerCardRect.minY,
              CGFloat(layout.bottom) == template.lowerCardRect.maxY,
              layout.bottom == contentBottom,
              upper.contains(template.heroPhotoRect),
              upper.contains(template.heroBrandingRect),
              lower.contains(template.portraitPhotoRect),
              lower.contains(template.portraitBrandingRect),
              lower.contains(template.gridRect),
              !template.heroBrandingRect.intersects(template.heroPhotoRect),
              !template.portraitBrandingRect.intersects(template.portraitPhotoRect),
              !template.gridRect.intersects(template.portraitPhotoRect),
              template.signatureBoxRect.contains(template.signatureRect),
              template.accentStars.allSatisfy({ upper.contains($0.bounds) || lower.contains($0.bounds) }),
              template.ornamentRules.allSatisfy({ lower.contains($0) && !$0.intersects(template.portraitBrandingRect) }),
              layout.wordmarks.allSatisfy({ wordmark in
                  template.accentStars.allSatisfy { !$0.bounds.intersects(wordmark.rect) }
              }) else {
            throw ReceiptComposerError.invalidLayout("photo pass cards overlap or contain misplaced elements")
        }
        for (index, field) in template.fields.enumerated() {
            guard template.gridRect.contains(field.cellRect),
                  field.cellRect.contains(field.labelRect),
                  field.cellRect.contains(field.valueRect),
                  !field.labelRect.intersects(field.valueRect),
                  template.accentStars.allSatisfy({ !$0.bounds.intersects(field.cellRect) }) else {
                throw ReceiptComposerError.invalidLayout("photo pass field \(field.kind) leaves its cell")
            }
            for other in template.fields.dropFirst(index + 1) where other.cellRect.insetBy(dx: 1, dy: 1).intersects(field.cellRect.insetBy(dx: 1, dy: 1)) {
                throw ReceiptComposerError.invalidLayout("photo pass fields \(field.kind) and \(other.kind) overlap")
            }
        }
        for block in layout.allTexts {
            guard let field = template.fields.first(where: { PhotoPassReceiptLayout.valueRole($0.kind) == block.role || block.role == .fieldLabel($0.kind.rawValue) }),
                  field.cellRect.contains(block.rect),
                  block.role == .fieldLabel(field.kind.rawValue) || field.valueRect.contains(block.rect) else {
                throw ReceiptComposerError.invalidLayout("photo pass text \(block.role) leaves its field")
            }
        }
    }

    nonisolated private static func validateFrame(_ frame: CGRect, name: String, inside canvas: CGRect) throws {
        guard frame.origin.x.isFinite,
              frame.origin.y.isFinite,
              frame.size.width.isFinite,
              frame.size.height.isFinite,
              frame.minX >= 0,
              frame.minY >= 0,
              frame.width >= 0,
              frame.height >= 0,
              frame.maxX <= canvas.maxX,
              frame.maxY <= canvas.maxY else {
            throw ReceiptComposerError.invalidLayout("\(name) frame is outside canvas: \(frame)")
        }
    }

    // MARK: Photos

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

    nonisolated static func preparePhotos(
        _ photos: [UIImage],
        for plan: ReceiptLayoutPlan,
        profile: PocketPixelsThermalPhotoProfile = .customerPrintDefault
    ) throws -> [ThermalPreparedPhoto] {
        var preparedPhotos: [ThermalPreparedPhoto] = []
        preparedPhotos.reserveCapacity(photos.count)
        for (index, photo) in photos.enumerated() {
            try Task.checkCancellation()
            guard let frame = plan.photoFrames.first(where: { $0.photoIndex == index }) else {
                throw ReceiptComposerError.renderFailed
            }

            // The same geometry framed the live camera, confirmation and review for this slot.
            let geometry = PhotoPresentationGeometry.resolve(
                format: plan.format,
                photoIndex: index,
                passportDesign: plan.passportLayout != nil ? .legacyPassport : .photoPassV2
            )
            // Passport keeps the full frame in storage, so its upright crop is applied here.
            // Other formats are stored at their capture crop and the thermal centre crop matches.
            let sourcePhoto = plan.format == .passport ? geometry.uprightPhoto(from: photo) : photo
            let targetPixelSize = geometry.preparedPixelSize(forOpening: frame.rect.size)
            let presentationMode = geometry.thermalPresentationMode
            let prepared = try autoreleasepool {
                try ThermalPhotoProcessor.prepare(
                    sourcePhoto,
                    targetPixelSize: targetPixelSize,
                    presentationMode: presentationMode,
                    profile: profile
                )
            }
            preparedPhotos.append(prepared)
        }
        return preparedPhotos
    }

    nonisolated private static func portraitHeight(for width: Int) -> Int {
        width * 4 / 3
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

    /// Borderless like the reference: the photograph meets the paper directly.
    nonisolated private static func drawPhoto(_ image: UIImage, in rect: CGRect, context: CGContext) {
        context.interpolationQuality = .high
        image.draw(in: rect)
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

    // MARK: Drawing

    nonisolated private static func drawHeader(
        textSnapshot: ReceiptTextSnapshot,
        layout: ReceiptHeaderLayout,
        customArtwork: EventArtwork?
    ) {
        layout.mastheadTexts.forEach(drawText)
        if let separator = layout.coBrandSeparator {
            drawCoBrandSeparator(in: separator)
            if let customArtwork, let frame = layout.customImageFrame {
                // Rendered at the logo's exact dot size: vectors stay sharp, bitmaps resample once.
                let rendered = EventHeaderImageProcessor.renderedArtwork(source: customArtwork, configuration: textSnapshot.headerConfiguration,
                                                                         frameSize: frame.size, contentRect: textSnapshot.headerContentBounds ?? CGRect(origin: .zero, size: customArtwork.size))
                rendered.image.draw(in: frame)
            }
            return
        }
        if let customArtwork, let frame = layout.customImageFrame {
            let rendered = EventHeaderImageProcessor.renderedHeader(
                source: customArtwork,
                configuration: textSnapshot.headerConfiguration,
                receiptWidth: CGFloat(BoothConfiguration.receiptWidth)
            )
            rendered.image.draw(in: frame)
        }
        EventTextBlockLayout.draw(layout.eventTextFrames)
        if let dividerY = layout.dividerY {
            drawLegacyDivider(y: dividerY)
        }
    }

    nonisolated private static func drawEditorial(
        layout: ReceiptEditorialLayout,
        textSnapshot: ReceiptTextSnapshot,
        artwork: EventArtwork?,
        qrImage: UIImage?,
        context: CGContext
    ) {
        drawFooter(layout.footer, context: context)
        layout.captionTexts.forEach(drawText)

        if let frame = layout.signatureFrame, let artwork {
            let rendered = EventHeaderImageProcessor.renderedSignature(source: artwork, configuration: textSnapshot.headerConfiguration)
            context.interpolationQuality = .high
            rendered.image.draw(in: frame)
        }
        EventTextBlockLayout.draw(layout.eventTextFrames)
        layout.creditTexts.forEach(drawText)

        if let separator = layout.qrSeparator { drawDashedRule(separator, context: context) }
        if let qrRect = layout.qrRect, let qrImage {
            context.interpolationQuality = .none
            qrImage.draw(in: qrRect)
        }
        if let qrRect = layout.qrRect, qrImage == nil {
            // Deliberately non-scannable sample state; never invent a gallery token.
            UIColor.black.setStroke()
            context.setLineWidth(1)
            context.stroke(qrRect.insetBy(dx: 12, dy: 12))
            let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.monospacedSystemFont(ofSize: 14, weight: .regular), .foregroundColor: UIColor.black]
            NSString(string: "SAMPLE\nNO LIVE GALLERY").draw(in: qrRect.insetBy(dx: 28, dy: qrRect.height / 2 - 20), withAttributes: attrs)
        }
        if let qrLabel = layout.qrLabel { drawText(qrLabel) }
        drawText(layout.sessionText)
    }

    nonisolated private static func drawFooter(_ footer: ReceiptFooterLayout, context: CGContext) {
        UIColor.black.setFill()
        footer.barcodeBars.forEach { context.fill($0) }
        footer.separatorFrames.forEach { context.fill($0) }
        if let monogram = ReceiptMonogramArtwork.image(pixelSize: footer.monogramFrame.size) {
            // Already rasterized at exact dot size: draw 1:1 without resampling. UIKit contexts
            // are flipped, so draw through UIImage to keep the artwork upright.
            context.interpolationQuality = .none
            UIImage(cgImage: monogram).draw(in: footer.monogramFrame)
        } else {
            drawMonogramFallback(in: footer.monogramFrame)
        }
        footer.dateTexts.forEach(drawText)
    }

    /// Typographic MTK used only if the monogram asset is missing from the bundle, so the footer
    /// never prints an unexplained gap.
    nonisolated private static func drawMonogramFallback(in rect: CGRect) {
        let font = MadeToKeepTheme.Typography.italicSerifUIFont(size: rect.height * 0.42)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.black]
        let text = NSString(string: "MTK")
        let size = text.size(withAttributes: attributes)
        text.draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attributes)
    }

    /// A thin vector × that survives 1-bit conversion without reading as a heavy glyph.
    nonisolated private static func drawCoBrandSeparator(in rect: CGRect) {
        let inset = CoBrandedHeaderGeometry.separatorLineWidth / 2
        let path = UIBezierPath()
        path.move(to: CGPoint(x: rect.minX + inset, y: rect.minY + inset))
        path.addLine(to: CGPoint(x: rect.maxX - inset, y: rect.maxY - inset))
        path.move(to: CGPoint(x: rect.maxX - inset, y: rect.minY + inset))
        path.addLine(to: CGPoint(x: rect.minX + inset, y: rect.maxY - inset))
        path.lineWidth = CoBrandedHeaderGeometry.separatorLineWidth
        path.lineCapStyle = .butt
        UIColor.black.setStroke()
        path.stroke()
    }

    nonisolated private static func drawDashedRule(_ rect: CGRect, context: CGContext) {
        UIColor.black.setFill()
        var x = rect.minX
        while x < rect.maxX {
            context.fill(CGRect(x: x, y: rect.minY, width: min(Metrics.qrSeparatorDash, rect.maxX - x), height: rect.height))
            x += Metrics.qrSeparatorDash * 2
        }
    }

    nonisolated private static func drawLegacyDivider(y: Int) {
        let margin = BoothConfiguration.receiptHorizontalMargin
        let path = UIBezierPath()
        path.move(to: CGPoint(x: margin, y: y))
        path.addLine(to: CGPoint(x: BoothConfiguration.receiptWidth - margin, y: y))
        path.lineWidth = 1
        UIColor.black.setStroke()
        path.stroke()
    }

    nonisolated private static func drawText(_ frame: ReceiptTextFrame) {
        NSString(string: frame.text).draw(at: frame.rect.origin, withAttributes: attributes(for: frame.style, size: frame.fontSize, tracking: frame.tracking))
    }

    // MARK: Typography

    nonisolated private static func makeTextFrame(
        _ text: String,
        style: ReceiptTextStyle,
        size: CGFloat,
        tracking: CGFloat,
        anchor: ReceiptTextAnchor,
        y: Int
    ) -> ReceiptTextFrame {
        let font = font(for: style, size: size)
        let measured = measuredWidth(text, font: font, tracking: tracking)
        // Kerning also follows the last glyph; position by the visible run so tracked text centers.
        let visible = max(0, measured - tracking)
        let x: CGFloat
        switch anchor {
        case .leading(let left): x = left
        case .center(let center): x = center - visible / 2
        case .trailing(let right): x = right - visible
        }
        return ReceiptTextFrame(
            style: style,
            text: text,
            rect: CGRect(x: floor(x), y: CGFloat(y), width: ceil(measured) + 1, height: ceil(font.lineHeight)),
            fontSize: size,
            tracking: tracking
        )
    }

    nonisolated private static func font(for style: ReceiptTextStyle, size: CGFloat) -> UIFont {
        switch style {
        case .wordmark, .creditWordmark:
            MadeToKeepTheme.Typography.italicSerifUIFont(size: size)
        case .studios, .caption, .creditStudios:
            // Medium rather than light so tracked capitals stay crisp on thermal paper.
            .systemFont(ofSize: size, weight: .medium)
        case .footer:
            // Typewriter-style date and time like the reference footer.
            .monospacedSystemFont(ofSize: size, weight: .medium)
        case .qrLabel:
            .systemFont(ofSize: size, weight: .semibold)
        case .sessionIdentifier:
            .monospacedDigitSystemFont(ofSize: size, weight: .medium)
        }
    }

    nonisolated private static func attributes(for style: ReceiptTextStyle, size: CGFloat, tracking: CGFloat) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font(for: style, size: size),
            .kern: tracking,
            .foregroundColor: UIColor.black
        ]
        if style == .wordmark || style == .creditWordmark {
            attributes[.strokeWidth] = thermalSerifStrokeWidth
            attributes[.strokeColor] = UIColor.black
        }
        return attributes
    }

    nonisolated private static func measuredWidth(_ text: String, font: UIFont, tracking: CGFloat) -> CGFloat {
        NSString(string: text).size(withAttributes: [.font: font, .kern: tracking]).width
    }

    nonisolated private static func visibleWidth(_ text: String, font: UIFont, tracking: CGFloat) -> CGFloat {
        max(0, measuredWidth(text, font: font, tracking: tracking) - tracking)
    }

    nonisolated private static let identifierFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = sessionIdentifierTimeZone
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    nonisolated private static let footerDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = sessionIdentifierTimeZone
        formatter.dateFormat = "MMM dd yyyy"
        return formatter
    }()

    nonisolated private static let footerTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = sessionIdentifierTimeZone
        formatter.dateFormat = "h:mm a"
        return formatter
    }()
}

nonisolated private func debugLog(_ message: String) {
#if DEBUG
    print("[ReceiptComposer] \(message)")
#endif
}
