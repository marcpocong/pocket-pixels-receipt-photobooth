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

            var y = 22
            drawCentered("POCKET PIXELS", y: y, width: width, font: .systemFont(ofSize: 34, weight: .bold))
            y += 38
            drawCentered("RECEIPT PHOTOBOOTH", y: y, width: width, font: .systemFont(ofSize: 18, weight: .semibold))
            y += 34
            drawDivider(y: y, margin: margin, width: width)

            if let groupFrame = plan.groupFrame {
                UIColor.black.setStroke()
                cgContext.setLineWidth(2)
                cgContext.stroke(groupFrame.insetBy(dx: 1, dy: 1))
            }

            for frame in plan.photoFrames {
                drawPhoto(photos[frame.photoIndex], in: frame.rect, context: cgContext)
            }

            y = Int((plan.photoFrames.map(\.rect.maxY).max() ?? CGFloat(y)) + 16)

            if let galleryURL {
                drawDivider(y: y, margin: margin, width: width)
                y += 12
                drawCentered("Scan to view & save your photos", y: y, width: width, font: .systemFont(ofSize: 17, weight: .semibold))
                y += 24
                if let qrImage = try? GalleryQRCodeGenerator.makeQRCodeImage(for: galleryURL, pixelSize: plan.qrSize) {
                    let qrX = (width - plan.qrSize) / 2
                    cgContext.interpolationQuality = .none
                    qrImage.draw(in: CGRect(x: qrX, y: y, width: plan.qrSize, height: plan.qrSize))
                }
                y += plan.qrSize + 12
            }

            drawCentered(receiptDateFormatter.string(from: date).uppercased(), y: y, width: width, font: .monospacedDigitSystemFont(ofSize: 15, weight: .regular))
            y += 20
            drawCentered(sessionIdentifier, y: y, width: width, font: .monospacedDigitSystemFont(ofSize: 13, weight: .regular))
            y += 18
            drawCentered("@pocketpixels.ceb", y: y, width: width, font: .systemFont(ofSize: 19, weight: .semibold))
            y += 24
            drawDivider(y: y, margin: margin, width: width)
        }

        guard let data = image.pngData(), image.size.width == CGFloat(width), image.size.height == CGFloat(height) else {
            throw ReceiptComposerError.renderFailed
        }

        debugLog("Composed \(format.rawValue) receipt \(sessionIdentifier). Dimensions: \(width)x\(height). Estimated length: \(String(format: "%.1f", Double(height) / 8.0)) mm.")

        return ComposedReceipt(
            imagePNGData: data,
            width: width,
            height: height,
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
        let top = 110
        let photoFrames: [ReceiptPhotoFrame]
        let groupFrame: CGRect?

        switch format {
        case .solo:
            let photoWidth = 450
            let rect = centeredPortraitRect(y: top, width: photoWidth, in: width)
            photoFrames = [ReceiptPhotoFrame(photoIndex: 0, rect: rect)]
            groupFrame = nil
        case .duo:
            let photoWidth = 300
            let first = centeredPortraitRect(y: top, width: photoWidth, in: width)
            let second = centeredPortraitRect(y: Int(first.maxY) + 12, width: photoWidth, in: width)
            photoFrames = [
                ReceiptPhotoFrame(photoIndex: 0, rect: first),
                ReceiptPhotoFrame(photoIndex: 1, rect: second)
            ]
            groupFrame = nil
        case .grid:
            let gap = 12
            let photoWidth = 264
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
            let photoWidth = 240
            let gap = 8
            let padding = 10
            let x = (width - photoWidth) / 2
            var frames: [ReceiptPhotoFrame] = []
            var y = top
            for index in 0..<3 {
                let rect = CGRect(x: x, y: y, width: photoWidth, height: portraitHeight(for: photoWidth))
                frames.append(ReceiptPhotoFrame(photoIndex: index, rect: rect))
                y = Int(rect.maxY) + gap
            }
            photoFrames = frames
            let bottom = Int(frames.last?.rect.maxY ?? CGFloat(top))
            groupFrame = CGRect(x: x - padding, y: top - padding, width: photoWidth + padding * 2, height: bottom - top + padding * 2)
        }

        let qrSectionHeight = includesGalleryQRCode ? 1 + 12 + 24 + receiptQRCodeSize + 12 : 0
        let footerHeight = 20 + 18 + 24 + 14
        let photoBottom = Int(photoFrames.map(\.rect.maxY).max() ?? CGFloat(top))
        let height = photoBottom + 16 + qrSectionHeight + footerHeight

        return ReceiptLayoutPlan(
            format: format,
            displayedPhotoIndexes: Array(0..<format.photoCount),
            photoFrames: photoFrames,
            groupFrame: groupFrame,
            width: width,
            height: height,
            qrSize: includesGalleryQRCode ? receiptQRCodeSize : 0
        )
    }

    nonisolated private static func centeredPortraitRect(y: Int, width photoWidth: Int, in receiptWidth: Int) -> CGRect {
        CGRect(
            x: (receiptWidth - photoWidth) / 2,
            y: y,
            width: photoWidth,
            height: portraitHeight(for: photoWidth)
        )
    }

    nonisolated private static func portraitHeight(for width: Int) -> Int {
        width * 4 / 3
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
