import CoreImage
import Foundation
import UIKit
import XCTest
@testable import PocketPixelsBooth

/// Editorial receipt redesign: branding modes, printed-QR toggle, captions, persistence,
/// session freezing and archive integrity. Every composition uses the production renderer.
final class ReceiptDesignSystemTests: XCTestCase {
    private static let date: Date = {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = ReceiptComposer.sessionIdentifierTimeZone
        components.year = 2026
        components.month = 10
        components.day = 8
        components.hour = 23
        components.minute = 45
        return components.date!
    }()
    private static let galleryURL = URL(string: "https://pocket-pixels-gallery.pocketpixels-ceb.workers.dev/?g=\(String(repeating: "d", count: 64))")!
    private static let artifactDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("BuildArtifacts/ReceiptRedesign", isDirectory: true)

    // MARK: Visual artifacts

    func testRenderEveryFormatAndBrandingCombination() throws {
        let artwork = try makeArtworkIdentifier(kind: .wideBanner)
        let monogram = try makeArtworkIdentifier(kind: .monogram)
        for format in BoothFormat.allCases {
            for qr in [false, true] {
                let name = "\(format.rawValue)_studio_\(qr ? "qr_on" : "qr_off")"
                try render(format: format, profile: nil, qr: qr, name: name)
            }
            try render(format: format, profile: eventProfile(mode: .studioFirst, artwork: monogram), qr: true, name: "\(format.rawValue)_event_studio_first_signature")
            try render(format: format, profile: eventProfile(mode: .eventFirst, artwork: artwork), qr: false, name: "\(format.rawValue)_event_first")
        }
        var credit = eventProfile(mode: .eventFirst, artwork: artwork)
        credit.receiptHeader.showsStudioCredit = true
        try render(format: .duo, profile: credit, qr: true, name: "duo_event_first_credit")
        try render(format: .solo, profile: eventProfile(mode: .studioFirst, artwork: nil, caption: "Anna & Mark\nForever starts today"), qr: false, name: "solo_event_caption")
        try render(format: .passport, profile: nil, qr: true, name: "passport_legacy_qr_on", passport: .debugFixture)
        for format in BoothFormat.allCases {
            try render(format: format, profile: nil, qr: true, name: "\(format.rawValue)_stickers", withStickers: true)
        }
    }

    func testPrintedQRSettingDefaultsOnAndPersistsIndependently() throws {
        let suiteName = "ReceiptDesignSystemTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertTrue(ReceiptPrintSettingsStore.load(defaults: defaults).includesPrintedGalleryQR)
        ReceiptPrintSettingsStore.save(ReceiptPrintOptions(includesPrintedGalleryQR: false), defaults: defaults)
        XCTAssertFalse(ReceiptPrintSettingsStore.load(defaults: defaults).includesPrintedGalleryQR)
    }

    func testPrintedQRChoiceReflowsEveryFormatWithoutRemovingGalleryURL() throws {
        for format in BoothFormat.allCases {
            let withQR = try compose(format: format, profile: nil, qr: true)
            let withoutQR = try compose(format: format, profile: nil, qr: false)

            XCTAssertTrue(withQR.includesPrintedGalleryQR, format.rawValue)
            XCTAssertFalse(withoutQR.includesPrintedGalleryQR, format.rawValue)
            XCTAssertLessThan(withoutQR.height, withQR.height, format.rawValue)
        }
    }

    func testCommittedSessionFreezesPhysicalPrintOptions() {
        let session = CommittedGallerySession(
            sessionIdentifier: "PP-FROZEN",
            createdAt: Self.date,
            galleryToken: String(repeating: "f", count: 64),
            galleryURL: Self.galleryURL,
            photos: samplePhotos(for: .solo),
            format: .solo,
            eventProfile: nil,
            printOptions: ReceiptPrintOptions(includesPrintedGalleryQR: false)
        )

        XCTAssertFalse(session.printOptions.includesPrintedGalleryQR)
        XCTAssertEqual(session.galleryURL, Self.galleryURL)
        XCTAssertFalse(session.galleryToken.isEmpty)
    }

    func testEventFirstWithoutArtworkUsesSafeStudioFallback() throws {
        let profile = eventProfile(mode: .eventFirst, artwork: nil)
        let plan = try ReceiptComposer.makeLayoutPlan(
            format: .duo,
            includesGalleryQRCode: false,
            eventProfile: profile,
            date: Self.date
        )

        XCTAssertEqual(plan.branding.placement, .studioFirst)
        XCTAssertTrue(plan.branding.showsStudioMasthead)
        XCTAssertEqual(plan.branding.warnings, [.eventFirstArtworkHidden])
    }

    // MARK: Reference footer

    func testEveryFormatPrintsTheThreePartFooterWithTheSessionTimeAndNoDefaultCaption() throws {
        // 2026-10-12 18:50 UTC is 2:50 AM on Oct 13 in Manila: the footer uses the session's
        // Asia/Manila time, never the render device's zone or the render time.
        let sessionDate = Date(timeIntervalSince1970: 1_791_831_000)
        for format in BoothFormat.allCases {
            for qr in [false, true] {
                let plan = try ReceiptComposer.makeLayoutPlan(
                    format: format,
                    includesGalleryQRCode: qr,
                    passport: format == .passport ? .photoPassDebugFixture : nil,
                    date: sessionDate,
                    footerStyle: .classicBarcodeAndGalleryQR
                )
                let footer = plan.footer
                XCTAssertEqual(footer.dateTexts.map(\.text), ["OCT 13 2026", "2:50 AM"], "\(format)")
                XCTAssertTrue(plan.captionLines.isEmpty, "\(format) prints no default caption")
                XCTAssertGreaterThan(CGFloat(footer.top), CGFloat(plan.contentBottom), "\(format) footer follows the photographs")
                XCTAssertEqual(footer.monogramFrame.midX, CGFloat(plan.width) / 2, accuracy: 1, "\(format) monogram is centred")
                XCTAssertLessThan(footer.barcodeFrame.maxX, footer.separatorFrames[0].minX)
                XCTAssertLessThan(footer.separatorFrames[1].maxX, footer.dateTexts.map(\.rect.minX).min() ?? 0)
                XCTAssertFalse(plan.mastheadFrames.isEmpty, "\(format) leads with the Made to Keep masthead")
                if let qrRect = plan.qrRect {
                    XCTAssertGreaterThan(qrRect.minY, CGFloat(footer.bottom), "\(format) functional QR sits below the decorative footer")
                } else {
                    XCTAssertFalse(qr, "\(format) prints the QR whenever it is enabled")
                }
            }
        }
    }

    func testFooterArtworkIsBundledDeterministicAndPureBlackOnWhite() throws {
        let plan = try ReceiptComposer.makeLayoutPlan(format: .solo, includesGalleryQRCode: false, date: Self.date)
        let monogram = try XCTUnwrap(ReceiptMonogramArtwork.image(pixelSize: plan.footer.monogramFrame.size), "The official monogram ships in the app bundle")
        XCTAssertEqual(monogram.width, Int(plan.footer.monogramFrame.width))
        XCTAssertEqual(ReceiptDecorativeBarcode.bars(originX: 0, y: 0, height: 10), ReceiptDecorativeBarcode.bars(originX: 0, y: 0, height: 10))
        XCTAssertEqual(ReceiptDecorativeBarcode.barWidths.count, ReceiptDecorativeBarcode.gapWidths.count + 1)

        let receipt = try compose(format: .solo, profile: nil, qr: false)
        let image = try XCTUnwrap(UIImage(data: receipt.imagePNGData)?.cgImage)
        let footerArtwork = [plan.footer.barcodeFrame, plan.footer.monogramFrame] + plan.footer.separatorFrames
        var inked = 0
        for rect in footerArtwork {
            for value in try grayValues(of: image, in: rect) {
                XCTAssertTrue(value < 8 || value > 247, "Footer artwork never prints grey that the dither would speckle")
                if value < 8 { inked += 1 }
            }
        }
        XCTAssertGreaterThan(inked, 1_000, "The barcode, rules and monogram actually print")
    }

    func testEventCaptionPrintsOnlyWhenConfiguredBelowTheFooter() throws {
        let plan = try ReceiptComposer.makeLayoutPlan(
            format: .grid,
            includesGalleryQRCode: true,
            eventProfile: eventProfile(mode: .studioFirst, artwork: nil, caption: "Anna & Mark\nForever starts today"),
            date: Self.date,
            footerStyle: .classicBarcodeAndGalleryQR
        )
        XCTAssertEqual(plan.captionLines, ["ANNA & MARK", "FOREVER STARTS TODAY"])
        XCTAssertTrue(plan.captionFrames.allSatisfy { $0.minY >= CGFloat(plan.footer.bottom) })
        XCTAssertTrue(plan.captionFrames.allSatisfy { $0.maxY <= (plan.qrRect?.minY ?? .infinity) })
    }

    func testEditorialCaptionNormalizesToTwoPrintSafeLines() {
        let caption = ReceiptEditorialCaption.normalized("  Another year with many wonderful memories to keep  ")
        let lines = caption.components(separatedBy: "\n")

        XCTAssertLessThanOrEqual(lines.count, ReceiptEditorialCaption.maximumLines)
        XCTAssertTrue(lines.allSatisfy { $0.count <= ReceiptEditorialCaption.maximumLineLength })
    }

    // MARK: Helpers

    private func render(format: BoothFormat, profile: EventProfile?, qr: Bool, name: String, passport: PassportSessionData? = nil, withStickers: Bool = false) throws {
        var receipt = try compose(format: format, profile: profile, qr: qr, passport: passport)
        if withStickers {
            // One bundled sticker per photo, deliberately pushed toward the edges.
            let regions = try XCTUnwrap(receipt.stickerLayout).regions.filter { if case .photo = $0.target { true } else { false } }
            let art = try StickerPrintPreparation.prepare(XCTUnwrap(BundledStickerFactory.image(for: "builtin.heart")))
            let stickers = regions.enumerated().map { index, region in
                FrozenStickerDecoration(
                    placement: StickerPlacement(id: UUID(), assetID: "builtin.heart", assetName: "Heart", provenance: .builtIn, frameIndex: 0,
                                                target: region.target, centerX: index.isMultiple(of: 2) ? 0.92 : 0.1, centerY: 0.92,
                                                scale: 0.45, rotation: 0.3, zOrder: index, aspectRatio: 1),
                    printImage: art
                )
            }
            receipt = try compose(format: format, profile: profile, qr: qr, passport: passport, stickers: stickers)
            XCTAssertEqual(receipt.drawnStickerPlacementIDs.count, stickers.count, "\(format) draws every sticker")
        }
        let image = try XCTUnwrap(UIImage(data: receipt.imagePNGData))
        let raster = try ThermalImageRasterizer.rasterize(image, purpose: .completeReceipt)
        let thermal = try XCTUnwrap(UIImage(data: raster.previewPNGData))
        writeArtifact(image, name: "\(name).png")
        writeArtifact(thermal, name: "\(name)_1bit.png")
        print("RECEIPT_ARTIFACT \(name) \(receipt.width)x\(receipt.height) \(String(format: "%.1f", receipt.estimatedLengthMillimeters))mm")
    }

    private func compose(format: BoothFormat, profile: EventProfile?, qr: Bool, passport: PassportSessionData? = nil, stickers: [FrozenStickerDecoration] = []) throws -> ComposedReceipt {
        try ReceiptComposer.compose(
            photos: samplePhotos(for: format),
            sessionIdentifier: ReceiptComposer.makeSessionIdentifier(date: Self.date),
            date: Self.date,
            galleryURL: Self.galleryURL,
            format: format,
            eventProfile: profile,
            passport: format == .passport ? (passport ?? .photoPassDebugFixture) : nil,
            printOptions: ReceiptPrintOptions(includesPrintedGalleryQR: qr),
            stickers: stickers
        )
    }

    private func eventProfile(mode: ReceiptBrandingMode?, artwork: String?, caption: String = "") -> EventProfile {
        var profile = EventProfile(
            isEnabled: true,
            eventName: "Anna & Mark",
            subtitle: "Our Wedding Day",
            includeEventDate: true,
            eventDate: Self.date,
            location: "Cebu City",
            shortMessage: "Thank you for celebrating"
        )
        profile.receiptHeader.brandingMode = mode
        if let artwork {
            profile.receiptHeader.mode = .customEventHeader
            profile.receiptHeader.assetIdentifier = artwork
        }
        profile.receiptDesign.editorialCaption = caption
        return profile
    }

    private enum ArtworkKind { case wideBanner, monogram, tall }

    private func makeArtworkIdentifier(kind: ArtworkKind) throws -> String {
        let size: CGSize = switch kind {
        case .wideBanner: CGSize(width: 1200, height: 300)
        case .monogram: CGSize(width: 600, height: 600)
        case .tall: CGSize(width: 300, height: 1500)
        }
        let image = UIGraphicsImageRenderer(size: size).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor.black.setStroke()
            context.cgContext.setLineWidth(size.width / 60)
            context.cgContext.stroke(CGRect(origin: .zero, size: size).insetBy(dx: size.width / 20, dy: size.height / 20))
            let text = kind == .monogram ? "A&M" : "ANNA & MARK"
            let font = UIFont(name: "Didot-Bold", size: size.height * (kind == .tall ? 0.06 : 0.28)) ?? .boldSystemFont(ofSize: 60)
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.black]
            let textSize = NSString(string: text).size(withAttributes: attributes)
            NSString(string: text).draw(at: CGPoint(x: (size.width - textSize.width) / 2, y: (size.height - textSize.height) / 2), withAttributes: attributes)
        }
        return try EventHeaderAssetStore().importImageData(XCTUnwrap(image.pngData()))
    }

    /// Development-only sample photographs: crops of the reference mockup when it is present,
    /// otherwise synthetic portraits.
    private func samplePhotos(for format: BoothFormat) -> [UIImage] {
        let referenceCrops: [CGRect] = [
            CGRect(x: 212, y: 300, width: 345, height: 520),
            CGRect(x: 700, y: 228, width: 360, height: 320),
            CGRect(x: 672, y: 566, width: 360, height: 310)
        ]
        if let reference = UIImage(contentsOfFile: Self.artifactDirectory.appendingPathComponent("reference.png").path)?.cgImage {
            let scale = CGFloat(reference.width) / 1230
            let crops = referenceCrops.compactMap { rect -> UIImage? in
                let pixelRect = CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale)
                return reference.cropping(to: pixelRect).map { UIImage(cgImage: $0) }
            }
            if crops.count == referenceCrops.count {
                switch format {
                case .solo: return [crops[0]]
                case .duo: return [crops[1], crops[2]]
                default: return (0..<format.photoCount).map { crops[$0 % crops.count] }
                }
            }
        }
        return (0..<format.photoCount).map { ReliabilityFixtures.syntheticPhoto(session: 900, photo: $0 + 1, format: format) }
    }

    private func grayValues(of image: CGImage, in rect: CGRect) throws -> [UInt8] {
        let cropped = try XCTUnwrap(image.cropping(to: rect))
        var pixels = [UInt8](repeating: 0, count: cropped.width * cropped.height)
        let context = try XCTUnwrap(CGContext(data: &pixels, width: cropped.width, height: cropped.height, bitsPerComponent: 8,
                                              bytesPerRow: cropped.width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: cropped.width, height: cropped.height))
        return pixels
    }

    private func writeArtifact(_ image: UIImage, name: String) {
        let output = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/StickerStudio/ReceiptRedesign", isDirectory: true)
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try? image.pngData()?.write(to: output.appendingPathComponent(name))
    }
}
