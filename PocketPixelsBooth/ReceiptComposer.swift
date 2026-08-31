//
//  ReceiptComposer.swift
//  PocketPixelsBooth
//
//  Created by marc on 8/30/26.
//

import Foundation
import UIKit

struct ComposedReceipt: Sendable {
    let imagePNGData: Data
    let width: Int
    let height: Int
    let sessionIdentifier: String
    let createdAt: Date
    let layoutStyle: ReceiptLayoutStyle
    let favoritePhotoIndex: Int

    var estimatedLengthMillimeters: Double {
        Double(height) / 8.0
    }
}

enum ReceiptLayoutStyle: String, CaseIterable, Identifiable, Sendable {
    case collage
    case single

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .collage:
            "Collage"
        case .single:
            "Single"
        }
    }

    var detailText: String {
        switch self {
        case .collage:
            "All 3 photos"
        case .single:
            "Your favorite photo"
        }
    }
}

struct ReceiptLayoutPlan: Sendable {
    let style: ReceiptLayoutStyle
    let favoritePhotoIndex: Int
    let displayedPhotoIndexes: [Int]
    let heroPhotoIndex: Int
    let secondaryPhotoIndexes: [Int]
    let width: Int
    let height: Int
    let qrSize: Int
}

enum ReceiptComposerError: Error, LocalizedError {
    case missingPhotos(expected: Int, actual: Int)
    case invalidFavoritePhotoIndex(Int)
    case renderFailed
    case heightExceeded(Int)

    var errorDescription: String? {
        switch self {
        case .missingPhotos(let expected, let actual):
            "Receipt requires \(expected) photos, but only \(actual) are available."
        case .invalidFavoritePhotoIndex(let index):
            "Favorite photo \(index + 1) is not available."
        case .renderFailed:
            "The receipt could not be rendered."
        case .heightExceeded(let height):
            "The composed receipt is too tall: \(height) pixels."
        }
    }
}

enum ReceiptComposer {
    nonisolated static let sessionIdentifierTimeZone = TimeZone(identifier: "Asia/Manila") ?? TimeZone(secondsFromGMT: 8 * 60 * 60)!

    nonisolated static func makeSessionIdentifier(date: Date = Date()) -> String {
        "PP-\(identifierFormatter.string(from: date))"
    }

    nonisolated static func compose(
        photos: [UIImage],
        sessionIdentifier: String,
        date: Date = Date(),
        galleryURL: URL? = nil,
        layoutStyle: ReceiptLayoutStyle = .collage,
        favoritePhotoIndex: Int = 0
    ) throws -> ComposedReceipt {
        guard photos.count == BoothConfiguration.photosPerSession else {
            throw ReceiptComposerError.missingPhotos(expected: BoothConfiguration.photosPerSession, actual: photos.count)
        }

        let plan = try makeLayoutPlan(
            style: layoutStyle,
            favoritePhotoIndex: favoritePhotoIndex,
            photoCount: photos.count,
            includesGalleryQRCode: galleryURL != nil
        )
        let width = BoothConfiguration.receiptWidth
        let margin = BoothConfiguration.receiptHorizontalMargin
        let contentWidth = width - (margin * 2)
        let height = plan.height

        guard height <= BoothConfiguration.receiptMaximumHeight else {
            throw ReceiptComposerError.heightExceeded(height)
        }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true

        let size = CGSize(width: width, height: height)
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let image = renderer.image { context in
            let cgContext = context.cgContext
            UIColor.white.setFill()
            cgContext.fill(CGRect(origin: .zero, size: size))

            var y = 30
            drawCentered("POCKET PIXELS", y: y, width: width, font: .systemFont(ofSize: 34, weight: .bold))
            y += 43
            drawCentered("RECEIPT PHOTOBOOTH", y: y, width: width, font: .systemFont(ofSize: 18, weight: .semibold))
            y += 34
            drawDivider(y: y, margin: margin, width: width)
            y += 20

            switch layoutStyle {
            case .collage:
                let heroRect = CGRect(x: margin, y: y, width: contentWidth, height: 300)
                drawPhoto(photos[plan.heroPhotoIndex], in: heroRect, context: cgContext)
                y += 312

                let gap = 12
                let secondaryWidth = (contentWidth - gap) / 2
                let secondaryHeight = 194
                for (offset, index) in plan.secondaryPhotoIndexes.enumerated() {
                    let x = margin + (offset * (secondaryWidth + gap))
                    let rect = CGRect(x: x, y: y, width: secondaryWidth, height: secondaryHeight)
                    drawPhoto(photos[index], in: rect, context: cgContext)
                }
                y += secondaryHeight + 18
            case .single:
                let heroRect = CGRect(x: margin, y: y, width: contentWidth, height: 360)
                drawPhoto(photos[plan.heroPhotoIndex], in: heroRect, context: cgContext)
                y += 378
            }

            if let galleryURL {
                drawDivider(y: y, margin: margin, width: width)
                y += 20
                drawCentered("Scan to view and save your photos", y: y, width: width, font: .systemFont(ofSize: 18, weight: .semibold))
                y += 30
                if let qrImage = try? GalleryQRCodeGenerator.makeQRCodeImage(for: galleryURL, pixelSize: plan.qrSize) {
                    let qrX = (width - plan.qrSize) / 2
                    cgContext.interpolationQuality = .none
                    qrImage.draw(in: CGRect(x: qrX, y: y, width: plan.qrSize, height: plan.qrSize))
                }
                y += plan.qrSize + 16
            }

            drawCentered(receiptDateFormatter.string(from: date), y: y, width: width, font: .monospacedDigitSystemFont(ofSize: 16, weight: .regular))
            y += 25
            drawCentered(sessionIdentifier, y: y, width: width, font: .monospacedDigitSystemFont(ofSize: 18, weight: .medium))
            y += 29
            drawCentered("@pocketpixels.ceb", y: y, width: width, font: .systemFont(ofSize: 20, weight: .semibold))
            y += 27
            drawDivider(y: y, margin: margin, width: width)
        }

        guard let data = image.pngData(), image.size.width == CGFloat(width), image.size.height == CGFloat(height) else {
            throw ReceiptComposerError.renderFailed
        }

        debugLog("Composed \(layoutStyle.rawValue) receipt \(sessionIdentifier). Dimensions: \(width)x\(height). Estimated length: \(String(format: "%.1f", Double(height) / 8.0)) mm.")

        return ComposedReceipt(
            imagePNGData: data,
            width: width,
            height: height,
            sessionIdentifier: sessionIdentifier,
            createdAt: date,
            layoutStyle: layoutStyle,
            favoritePhotoIndex: favoritePhotoIndex
        )
    }

    nonisolated static func makeLayoutPlan(
        style: ReceiptLayoutStyle,
        favoritePhotoIndex: Int,
        photoCount: Int = BoothConfiguration.photosPerSession,
        includesGalleryQRCode: Bool = true
    ) throws -> ReceiptLayoutPlan {
        guard photoCount == BoothConfiguration.photosPerSession else {
            throw ReceiptComposerError.missingPhotos(expected: BoothConfiguration.photosPerSession, actual: photoCount)
        }

        guard 0..<photoCount ~= favoritePhotoIndex else {
            throw ReceiptComposerError.invalidFavoritePhotoIndex(favoritePhotoIndex)
        }

        let displayedIndexes: [Int]
        let secondaryIndexes: [Int]
        switch style {
        case .collage:
            secondaryIndexes = (0..<photoCount).filter { $0 != favoritePhotoIndex }
            displayedIndexes = [favoritePhotoIndex] + secondaryIndexes
        case .single:
            secondaryIndexes = []
            displayedIndexes = [favoritePhotoIndex]
        }

        let headerHeight = 128
        let photoSectionHeight: Int
        switch style {
        case .collage:
            photoSectionHeight = 300 + 12 + 194 + 18
        case .single:
            photoSectionHeight = 360 + 18
        }
        let qrSectionHeight = includesGalleryQRCode ? 1 + 20 + 30 + 240 + 16 : 0
        let footerHeight = 25 + 29 + 27 + 17
        let height = headerHeight + photoSectionHeight + qrSectionHeight + footerHeight

        return ReceiptLayoutPlan(
            style: style,
            favoritePhotoIndex: favoritePhotoIndex,
            displayedPhotoIndexes: displayedIndexes,
            heroPhotoIndex: favoritePhotoIndex,
            secondaryPhotoIndexes: secondaryIndexes,
            width: BoothConfiguration.receiptWidth,
            height: height,
            qrSize: includesGalleryQRCode ? 240 : 0
        )
    }

    nonisolated private static func drawPhoto(_ image: UIImage, in rect: CGRect, context: CGContext) {
        drawAspectFill(image, in: rect, context: context)
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
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

nonisolated private func debugLog(_ message: String) {
#if DEBUG
    print("[ReceiptComposer] \(message)")
#endif
}
