//
//  EventArtwork.swift
//  PocketPixelsBooth
//

import CoreGraphics
import Foundation
import UIKit

nonisolated enum EventArtworkKind: String, Sendable {
    case bitmap
    case vector
}

nonisolated enum EventArtworkError: Error, LocalizedError, Equatable {
    case unreadable
    case encryptedPDF
    case multiPagePDF(pageCount: Int)
    case invalidPageSize
    case fileTooLarge

    var errorDescription: String? {
        switch self {
        case .unreadable:
            "That file is not a readable PNG, JPEG or PDF."
        case .encryptedPDF:
            "That PDF is password protected. Export an unprotected copy of the artwork."
        case .multiPagePDF(let pageCount):
            "That PDF has \(pageCount) pages. Export the logo as a single-page PDF."
        case .invalidPageSize:
            "That PDF page has no usable size."
        case .fileTooLarge:
            "That file is too large. Use artwork under 25 MB."
        }
    }
}

/// Immutable, decoded event artwork.
///
/// Bitmaps (PNG/JPEG) draw from their stored pixels. Vector artwork (a single-page PDF) is drawn
/// straight into the destination context, so its edges are rendered at the receipt's own
/// 576-dot resolution instead of being scaled up from a small cached bitmap.
///
/// Transparent areas are never filled here: every caller draws onto white paper first, so
/// transparency composites against the receipt background before thermal conversion.
nonisolated final class EventArtwork: @unchecked Sendable {
    nonisolated static let maximumFileSize = 25 * 1024 * 1024
    nonisolated private static let maximumPageDimension: CGFloat = 20_000

    let kind: EventArtworkKind
    /// Intrinsic size: pixels for bitmaps, rotated crop-box points for PDFs. Always finite and positive.
    let size: CGSize

    private let bitmap: UIImage?
    private let document: CGPDFDocument?
    private let page: CGPDFPage?
    /// CGPDFPage drawing is serialized so previews and receipt composition can share one instance.
    private let drawLock = NSLock()
    private let boundsLock = NSLock()
    private var cachedContentBounds: CGRect?

    init(image: UIImage) {
        kind = .bitmap
        bitmap = image
        document = nil
        page = nil
        size = CGSize(width: max(1, image.size.width), height: max(1, image.size.height))
    }

    private init(document: CGPDFDocument, page: CGPDFPage, size: CGSize) {
        kind = .vector
        bitmap = nil
        self.document = document
        self.page = page
        self.size = size
    }

    nonisolated static func isPDF(_ data: Data) -> Bool {
        data.prefix(5) == Data("%PDF-".utf8)
    }

    /// Validates and opens a single-page PDF. Multi-page documents are rejected rather than
    /// guessing which page holds the logo.
    nonisolated static func makeVector(pdfData data: Data) throws -> EventArtwork {
        guard data.count <= maximumFileSize else { throw EventArtworkError.fileTooLarge }
        guard isPDF(data),
              let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider) else {
            throw EventArtworkError.unreadable
        }
        guard !document.isEncrypted || (document.unlockWithPassword("") && document.isUnlocked) else {
            throw EventArtworkError.encryptedPDF
        }
        guard document.numberOfPages == 1 else {
            throw document.numberOfPages < 1 ? EventArtworkError.unreadable : EventArtworkError.multiPagePDF(pageCount: document.numberOfPages)
        }
        guard let page = document.page(at: 1) else { throw EventArtworkError.unreadable }
        let box = page.getBoxRect(.cropBox)
        let rotated = page.rotationAngle % 180 != 0
        let size = rotated ? CGSize(width: box.height, height: box.width) : box.size
        guard size.width.isFinite, size.height.isFinite,
              size.width >= 1, size.height >= 1,
              size.width <= maximumPageDimension, size.height <= maximumPageDimension else {
            throw EventArtworkError.invalidPageSize
        }
        return EventArtwork(document: document, page: page, size: size)
    }

    /// Draws the artwork scaled to `rect` (UIKit top-left coordinates). Does not paint a background.
    func draw(in rect: CGRect, context: CGContext) {
        guard rect.width.isFinite, rect.height.isFinite, rect.width > 0, rect.height > 0 else { return }
        if let bitmap {
            UIGraphicsPushContext(context)
            bitmap.draw(in: rect, blendMode: .normal, alpha: 1)
            UIGraphicsPopContext()
            return
        }
        guard let page else { return }
        drawLock.lock()
        defer { drawLock.unlock() }

        let box = page.getBoxRect(.cropBox)
        context.saveGState()
        defer { context.restoreGState() }
        context.interpolationQuality = .high
        context.setShouldAntialias(true)
        // Flip into PDF space with the origin at the rect's bottom-left, in intrinsic units.
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: rect.width / size.width, y: -rect.height / size.height)
        switch (page.rotationAngle % 360 + 360) % 360 {
        case 90:
            context.translateBy(x: 0, y: size.height)
            context.rotate(by: -.pi / 2)
        case 180:
            context.translateBy(x: size.width, y: size.height)
            context.rotate(by: .pi)
        case 270:
            context.translateBy(x: size.width, y: 0)
            context.rotate(by: .pi / 2)
        default:
            break
        }
        context.translateBy(x: -box.minX, y: -box.minY)
        context.clip(to: box)
        context.drawPDFPage(page)
    }

    /// The visible mark inside the artwork, in intrinsic units: transparent and near-white
    /// margins are excluded so a padded logo is sized by what actually prints. Never smaller
    /// than the drawn content; falls back to the whole artwork when nothing is visible.
    var contentBounds: CGRect {
        boundsLock.lock()
        defer { boundsLock.unlock() }
        if let cachedContentBounds { return cachedContentBounds }
        let measured = Self.measureContentBounds(of: self)
        cachedContentBounds = measured
        return measured
    }

    private static func measureContentBounds(of artwork: EventArtwork) -> CGRect {
        let whole = CGRect(origin: .zero, size: artwork.size)
        let sampleLimit: CGFloat = 512
        let factor = min(1, sampleLimit / max(artwork.size.width, artwork.size.height))
        let width = max(1, Int(ceil(artwork.size.width * factor)))
        let height = max(1, Int(ceil(artwork.size.height * factor)))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return whole }
        // UIKit-style top-left coordinates so rows map directly to y.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        artwork.draw(in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)), context: context)
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width {
                let index = (y * width + x) * 4
                let alpha = Int(pixels[index + 3])
                guard alpha > 24 else { continue }
                // Premultiplied colour: visible means noticeably darker than white paper.
                let darkest = min(Int(pixels[index]), Int(pixels[index + 1]), Int(pixels[index + 2]))
                guard darkest * 100 < alpha * 94 else { continue }
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return whole }
        // One sample pixel of padding on each side so anti-aliased edges are never clipped.
        let rect = CGRect(x: CGFloat(minX - 1) / factor, y: CGFloat(minY - 1) / factor,
                          width: CGFloat(maxX - minX + 3) / factor, height: CGFloat(maxY - minY + 3) / factor)
        return rect.intersection(whole).isNull ? whole : rect.intersection(whole)
    }

    /// A bitmap for thumbnails, quality analysis and layouts that need a `UIImage`.
    /// Bitmaps return their stored pixels unchanged; vectors render at the requested size.
    func image(fitting maximumPixelDimension: CGFloat = 1_200) -> UIImage {
        if let bitmap { return bitmap }
        let limit = max(1, maximumPixelDimension)
        let factor = limit / max(size.width, size.height)
        return image(pixelSize: CGSize(width: size.width * factor, height: size.height * factor))
    }

    /// Renders at an exact pixel size on a transparent background (vectors stay sharp).
    func image(pixelSize: CGSize) -> UIImage {
        let target = CGSize(width: max(1, floor(pixelSize.width)), height: max(1, floor(pixelSize.height)))
        if let bitmap, bitmap.size == target { return bitmap }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: target, format: format).image { context in
            draw(in: CGRect(origin: .zero, size: target), context: context.cgContext)
        }
    }
}
