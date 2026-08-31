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

    var estimatedLengthMillimeters: Double {
        Double(height) / 8.0
    }
}

enum ReceiptComposerError: Error, LocalizedError {
    case missingPhotos(expected: Int, actual: Int)
    case renderFailed
    case heightExceeded(Int)

    var errorDescription: String? {
        switch self {
        case .missingPhotos(let expected, let actual):
            "Receipt requires \(expected) photos, but only \(actual) are available."
        case .renderFailed:
            "The receipt could not be rendered."
        case .heightExceeded(let height):
            "The composed receipt is too tall: \(height) pixels."
        }
    }
}

enum ReceiptComposer {
    nonisolated static let sessionIdentifierTimeZone = TimeZone(secondsFromGMT: 0)!

    nonisolated static func makeSessionIdentifier(date: Date = Date()) -> String {
        "PP-\(identifierFormatter.string(from: date))"
    }

    nonisolated static func compose(
        photos: [UIImage],
        sessionIdentifier: String,
        date: Date = Date(),
        galleryURL: URL? = nil
    ) throws -> ComposedReceipt {
        guard photos.count == BoothConfiguration.photosPerSession else {
            throw ReceiptComposerError.missingPhotos(expected: BoothConfiguration.photosPerSession, actual: photos.count)
        }

        let width = BoothConfiguration.receiptWidth
        let margin = BoothConfiguration.receiptHorizontalMargin
        let contentWidth = width - (margin * 2)
        let photoHeight = Int(round(Double(contentWidth) * 3.0 / 4.0))
        let headerHeight = 150
        let labelHeight = 24
        let photoGap = 18
        let qrSize = galleryURL == nil ? 0 : 240
        let qrSectionHeight = galleryURL == nil ? 0 : 330
        let footerHeight = 258 + qrSectionHeight
        let height = headerHeight + (photos.count * (labelHeight + photoHeight + photoGap)) + footerHeight

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
            y += 44
            drawDivider(y: y, margin: margin, width: width)
            y += 28

            for (index, photo) in photos.enumerated() {
                drawText(String(format: "%02d", index + 1), x: margin, y: y, font: .monospacedDigitSystemFont(ofSize: 16, weight: .semibold), alignment: .left, width: contentWidth)
                y += labelHeight

                let rect = CGRect(x: margin, y: y, width: contentWidth, height: photoHeight)
                drawAspectFill(photo, in: rect, context: cgContext)
                UIColor.black.setStroke()
                cgContext.setLineWidth(2)
                cgContext.stroke(rect.insetBy(dx: 1, dy: 1))
                y += photoHeight + photoGap
            }

            if let galleryURL {
                y += 8
                drawDivider(y: y, margin: margin, width: width)
                y += 24
                drawCentered("Scan to view and save your photos", y: y, width: width, font: .systemFont(ofSize: 18, weight: .semibold))
                y += 34
                if let qrImage = try? GalleryQRCodeGenerator.makeQRCodeImage(for: galleryURL, pixelSize: qrSize) {
                    let qrX = (width - qrSize) / 2
                    cgContext.interpolationQuality = .none
                    qrImage.draw(in: CGRect(x: qrX, y: y, width: qrSize, height: qrSize))
                }
                y += qrSize + 18
                drawCentered("Pocket Pixels Cebu", y: y, width: width, font: .systemFont(ofSize: 16, weight: .medium))
                y += 36
            }

            y += 10
            drawDivider(y: y, margin: margin, width: width)
            y += 26
            drawCentered(receiptDateFormatter.string(from: date), y: y, width: width, font: .monospacedDigitSystemFont(ofSize: 16, weight: .regular))
            y += 28
            drawCentered(sessionIdentifier, y: y, width: width, font: .monospacedDigitSystemFont(ofSize: 18, weight: .medium))
            y += 34
            drawCentered("@pocketpixels.ceb", y: y, width: width, font: .systemFont(ofSize: 20, weight: .semibold))
            y += 30
            drawCentered("Cebu", y: y, width: width, font: .systemFont(ofSize: 18, weight: .regular))
            y += 34
            drawCentered("thanks for collecting moments with us.", y: y, width: width, font: .systemFont(ofSize: 16, weight: .regular))
            y += 38
            drawDivider(y: y, margin: margin, width: width)
        }

        guard let data = image.pngData(), image.size.width == CGFloat(width), image.size.height == CGFloat(height) else {
            throw ReceiptComposerError.renderFailed
        }

        debugLog("Composed receipt \(sessionIdentifier). Dimensions: \(width)x\(height). Estimated length: \(String(format: "%.1f", Double(height) / 8.0)) mm.")

        return ComposedReceipt(
            imagePNGData: data,
            width: width,
            height: height,
            sessionIdentifier: sessionIdentifier,
            createdAt: date
        )
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
