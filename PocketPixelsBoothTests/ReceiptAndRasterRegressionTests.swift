import Foundation
import XCTest
import UIKit
import CoreImage
@testable import PocketPixelsBooth

final class ReceiptAndRasterRegressionTests: XCTestCase {
    func testReceiptMastheadUsesEstablished2024Branding() {
        XCTAssertEqual(ReceiptComposer.mastheadEstablishedText, "EST. 2024")
    }

    func testReceiptLayoutValidForEveryBoothFormat() throws {
        for format in BoothFormat.allCases {
            let plan = try ReceiptComposer.makeLayoutPlan(format: format, includesGalleryQRCode: true)
            try assertValidLayout(plan)
            let receipt = try ReceiptComposer.compose(
                photos: photos(for: format, session: 1),
                sessionIdentifier: "PP-20260907-\(format.rawValue.uppercased())",
                date: Date(timeIntervalSince1970: 1_788_692_040),
                galleryURL: URL(string: "https://example.com/gallery/\(format.rawValue)")!,
                format: format
            )
            XCTAssertEqual(receipt.width, BoothConfiguration.receiptWidth)
            XCTAssertLessThanOrEqual(receipt.height, BoothConfiguration.receiptMaximumHeight)
            XCTAssertGreaterThan(receipt.imagePNGData.count, 0)
        }
    }

    func testExtremeEventTextDoesNotOverlapReceiptSections() throws {
        let profile = EventProfile(
            isEnabled: true,
            eventName: String(repeating: "W", count: EventProfile.eventNameLimit),
            subtitle: String(repeating: "HOSTS AND FRIENDS ", count: 4),
            includeEventDate: true,
            eventDate: Date(timeIntervalSince1970: 1_788_692_040),
            location: String(repeating: "CEBU ", count: 12),
            shortMessage: String(repeating: "A VERY LONG MESSAGE ", count: 5)
        ).normalized()

        for format in BoothFormat.allCases {
            let plan = try ReceiptComposer.makeLayoutPlan(format: format, includesGalleryQRCode: true, eventProfile: profile)
            try assertValidLayout(plan)
            let receipt = try ReceiptComposer.compose(
                photos: photos(for: format, session: 2),
                sessionIdentifier: "PP-20260907-EVENT-\(format.rawValue)",
                date: Date(timeIntervalSince1970: 1_788_692_040),
                galleryURL: URL(string: "https://example.com/event/\(format.rawValue)")!,
                format: format,
                eventProfile: profile
            )
            XCTAssertLessThanOrEqual(receipt.height, BoothConfiguration.receiptMaximumHeight)
        }
    }

    func testRasterOutputIsDeterministic() throws {
        let image = testPatternImage(kind: .checkerboard)
        let first = try ThermalImageRasterizer.rasterize(image, purpose: .completeReceipt)
        let second = try ThermalImageRasterizer.rasterize(image, purpose: .completeReceipt)

        XCTAssertEqual(first.width, ThermalImageRasterizer.printWidth)
        XCTAssertEqual(first.widthBytes, ThermalImageRasterizer.widthBytes)
        XCTAssertEqual(first.rasterData, second.rasterData)
        XCTAssertEqual(first.rasterCommand, second.rasterCommand)
        XCTAssertEqual(first.rasterData.count, first.widthBytes * first.height)
    }

    func testRasterCommandIntegrity() throws {
        for kind in RasterPatternKind.allCases {
            let rasterized = try ThermalImageRasterizer.rasterize(testPatternImage(kind: kind), purpose: .completeReceipt)
            XCTAssertEqual(rasterized.rasterCommand.prefix(6), Data([0x1D, 0x76, 0x30, 0x00, 0x48, 0x00]))
            XCTAssertEqual(rasterized.rasterCommand.count, 8 + rasterized.rasterData.count)
            XCTAssertEqual(rasterized.rasterData.count, ThermalImageRasterizer.widthBytes * rasterized.height)
            XCTAssertTrue(rasterized.sanitizationReport.finalSafetyScanPassed)
            try RasterCommandSanitizer.validateNoReservedPatterns(in: rasterized.rasterData)
            try RasterCommandSanitizer.validateOutboundJob(
                heading: ThermalImageRasterizer.receiptPrintHeading(),
                rasterCommand: rasterized.rasterCommand,
                finishing: ThermalImageRasterizer.photoTestFinishing(),
                rasterDataRange: 8..<rasterized.rasterCommand.count
            )
        }
    }

    func testGridSixIdentityAndLegacyCodableValues() throws {
        XCTAssertEqual(BoothFormat.gridSix.photoCount, 6)
        XCTAssertEqual(BoothFormat.gridSix.displayName, "Grid 6")
        XCTAssertEqual(BoothFormat.gridSix.shortDescription, "Six-photo grid")
        XCTAssertEqual(BoothFormat.gridSix.reviewSummary, "GRID 6 · 6 PHOTOS")
        XCTAssertEqual(BoothConfiguration.maximumPhotosPerSession, 6)
        for format in BoothFormat.allCases {
            XCTAssertEqual(try JSONDecoder().decode(BoothFormat.self, from: JSONEncoder().encode(format)), format)
        }
        for raw in ["solo", "duo", "grid", "strip"] {
            XCTAssertEqual(try JSONDecoder().decode(BoothFormat.self, from: Data("\"\(raw)\"".utf8)).rawValue, raw)
        }
    }

    func testGridSixUsesThreeRowsOfExistingGridTiles() throws {
        let four = try ReceiptComposer.makeLayoutPlan(format: .grid)
        let six = try ReceiptComposer.makeLayoutPlan(format: .gridSix)
        try assertValidLayout(six)
        XCTAssertEqual(six.displayedPhotoIndexes, [0, 1, 2, 3, 4, 5])
        XCTAssertEqual(Array(six.photoFrames.prefix(4)).map(\.rect), four.photoFrames.map(\.rect))
        XCTAssertEqual(Set(six.photoFrames.map { $0.rect.minX }).count, 2)
        XCTAssertEqual(Set(six.photoFrames.map { $0.rect.minY }).count, 3)
        let tile = six.photoFrames[0].rect
        let gapX = six.photoFrames[1].rect.minX - tile.maxX
        let gapY = six.photoFrames[2].rect.minY - tile.maxY
        XCTAssertEqual(gapX, gapY)
        for (index, frame) in six.photoFrames.enumerated() {
            XCTAssertEqual(frame.rect.width, tile.width)
            XCTAssertEqual(frame.rect.height, tile.height)
            XCTAssertEqual(frame.rect.height, floor(tile.width * 4 / 3))
            XCTAssertEqual(frame.rect.minY, tile.minY + CGFloat(index / 2) * (tile.height + gapY))
            for other in six.photoFrames where other.photoIndex != frame.photoIndex {
                XCTAssertFalse(frame.rect.intersects(other.rect))
            }
        }
        XCTAssertEqual(six.height - four.height, Int(tile.height + gapY))
        XCTAssertGreaterThan(six.previewContentHeight, Int(six.photoFrames[5].rect.maxY))
        XCTAssertGreaterThan(six.height, six.previewContentHeight)
    }

    func testGridSixHeaderEventAndQRCombinationsAndDimensions() throws {
        let headerImage = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 2000)).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 100, height: 2000))
        }
        let assetStore = try EventHeaderAssetStore()
        let identifier = try assetStore.importImageData(XCTUnwrap(headerImage.pngData()))
        let date = Date(timeIntervalSince1970: 1_788_692_040)
        let galleryURL = URL(string: "https://example.com/?g=\(String(repeating: "a", count: 64))")!
        let sourcePhotos = photos(for: .gridSix, session: 6)
        let standard = try ReceiptComposer.makeLayoutPlan(format: .gridSix, includesGalleryQRCode: true)
        print("GRID6_DIMENSIONS standardQR=\(standard.width)x\(standard.height)")
        let noQR = try ReceiptComposer.compose(photos: sourcePhotos, sessionIdentifier: "PP-GRID6-STANDARD", date: date, format: .gridSix)
        print("GRID6_DIMENSIONS standardNoQR=\(noQR.width)x\(noQR.height)")
        for mode in [ReceiptHeaderMode.pocketPixelsDefault, .none, .customEventHeader] {
            for shown in [false, true] {
                for qr in [false, true] {
                    var profile = EventProfile(
                        isEnabled: true,
                        eventName: String(repeating: "W", count: EventProfile.eventNameLimit),
                        subtitle: String(repeating: "W", count: EventProfile.subtitleLimit),
                        includeEventDate: true,
                        eventDate: date,
                        location: String(repeating: "W", count: EventProfile.locationLimit),
                        shortMessage: String(repeating: "W", count: EventProfile.shortMessageLimit)
                    )
                    profile.receiptHeader.mode = mode
                    profile.receiptHeader.assetIdentifier = identifier
                    profile.receiptHeader.scale = ReceiptHeaderConfiguration.maximumScale
                    profile.receiptHeader.topSpacing = ReceiptHeaderConfiguration.maximumSpacing
                    profile.receiptHeader.bottomSpacing = ReceiptHeaderConfiguration.maximumSpacing
                    profile.showEventTextBlock = shown
                    let plan = try ReceiptComposer.makeLayoutPlan(format: .gridSix, includesGalleryQRCode: qr, eventProfile: profile)
                    try assertValidLayout(plan)
                    XCTAssertEqual(plan.headerMode, mode)
                    XCTAssertEqual(plan.showsEventTextBlock, shown)
                    let receipt = try ReceiptComposer.compose(photos: sourcePhotos, sessionIdentifier: "PP-GRID6-EVENT", date: date, galleryURL: qr ? galleryURL : nil, format: .gridSix, eventProfile: profile)
                    XCTAssertEqual(receipt.height, plan.height)
                    XCTAssertEqual(receipt.width, 576)
                    if shown && qr { print("GRID6_DIMENSIONS \(mode.rawValue)MaxEventQR=\(plan.width)x\(plan.height)") }
                }
            }
        }
    }

    func testGridSixCompleteReceiptRasterAndArchiveReprintAreIdentical() throws {
        let sourcePhotos = photos(for: .gridSix, session: 66)
        let date = Date(timeIntervalSince1970: 1_788_692_040)
        let token = String(repeating: "a", count: 64)
        let url = URL(string: "https://example.com/?g=\(token)")!
        let receipt = try ReceiptComposer.compose(photos: sourcePhotos, sessionIdentifier: "PP-GRID6-ARCHIVE", date: date, galleryURL: url, format: .gridSix)
        let image = try XCTUnwrap(UIImage(data: receipt.imagePNGData))
        let first = try ThermalImageRasterizer.rasterize(image, purpose: .completeReceipt)
        let second = try ThermalImageRasterizer.rasterize(image, purpose: .completeReceipt)
        XCTAssertEqual(first.rasterData, second.rasterData)
        XCTAssertEqual(first.rasterCommand, second.rasterCommand)
        XCTAssertEqual(first.height, receipt.height)
        for preview in [image, try XCTUnwrap(UIImage(data: first.previewPNGData))] {
            let detector = try XCTUnwrap(CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
            let messages = detector.features(in: CIImage(cgImage: try XCTUnwrap(preview.cgImage)))
                .compactMap { ($0 as? CIQRCodeFeature)?.messageString }
            XCTAssertTrue(messages.contains(url.absoluteString))
            let attachment = XCTAttachment(image: preview)
            attachment.name = "Grid6-full-receipt"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try RecentSessionArchiveStore(directoryURL: directory)
        let thumbnails = try sourcePhotos.map { try XCTUnwrap($0.pngData()) }
        let committed = CommittedGallerySession(sessionIdentifier: receipt.sessionIdentifier, createdAt: date, galleryToken: token, galleryURL: url, photos: sourcePhotos, format: .gridSix, eventProfile: nil)
        try store.save(RecentSessionArchivePayload(committedSession: committed, composedReceipt: receipt, receiptPreviewPNGData: receipt.imagePNGData, thermalPreviewPNGData: first.previewPNGData, rasterizedImage: first, photoThumbnailData: thumbnails))
        let reopened = try RecentSessionArchiveStore(directoryURL: directory)
        let loaded = try reopened.load(archiveID: token)
        XCTAssertEqual(loaded.summary.format, .gridSix)
        XCTAssertEqual(loaded.summary.photoCount, 6)
        XCTAssertEqual(loaded.thumbnailData, thumbnails)
        XCTAssertEqual(loaded.receiptPreviewPNGData, receipt.imagePNGData)
        XCTAssertEqual(loaded.rasterizedImage.rasterCommand, first.rasterCommand)
        try reopened.markReprinted(archiveID: token, copies: 3)
        XCTAssertEqual(try reopened.load(archiveID: token).summary.reprintCount, 3)
    }

    private func assertValidLayout(_ plan: ReceiptLayoutPlan) throws {
        XCTAssertEqual(plan.width, BoothConfiguration.receiptWidth)
        XCTAssertGreaterThan(plan.height, 0)
        XCTAssertLessThanOrEqual(plan.height, BoothConfiguration.receiptMaximumHeight)
        XCTAssertEqual(plan.displayedPhotoIndexes, Array(0..<plan.format.photoCount))
        XCTAssertEqual(plan.photoFrames.count, plan.format.photoCount)

        let canvas = CGRect(x: 0, y: 0, width: plan.width, height: plan.height)
        var previous: CGRect?
        for frame in plan.photoFrames.sorted(by: { $0.photoIndex < $1.photoIndex }) {
            XCTAssertTrue(canvas.contains(frame.rect), "Photo frame \(frame.photoIndex) exceeds receipt canvas")
            XCTAssertGreaterThan(frame.rect.width, 0)
            XCTAssertGreaterThan(frame.rect.height, 0)
            if let previous {
                XCTAssertFalse(previous.intersects(frame.rect), "Photo frames overlap")
            }
            previous = frame.rect
        }
        if let groupFrame = plan.groupFrame {
            XCTAssertTrue(canvas.contains(groupFrame))
        }
    }

    private func photos(for format: BoothFormat, session: Int) -> [UIImage] {
        (0..<format.photoCount).map {
            ReliabilityFixtures.syntheticPhoto(session: session, photo: $0 + 1, format: format)
        }
    }

    private enum RasterPatternKind: CaseIterable {
        case white
        case black
        case checkerboard
        case grayscaleRamp
        case faceLikeGradient
        case highFrequency
        case mostlyDark
        case mostlyBright
    }

    private func testPatternImage(kind: RasterPatternKind) -> UIImage {
        let size = CGSize(width: ThermalImageRasterizer.printWidth, height: 96)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let cg = context.cgContext
            for y in 0..<Int(size.height) {
                for x in 0..<Int(size.width) {
                    let value: CGFloat
                    switch kind {
                    case .white:
                        value = 1
                    case .black:
                        value = 0
                    case .checkerboard:
                        value = ((x / 8 + y / 8).isMultiple(of: 2)) ? 0 : 1
                    case .grayscaleRamp:
                        value = CGFloat(x) / size.width
                    case .faceLikeGradient:
                        let dx = (CGFloat(x) - size.width / 2) / (size.width / 2)
                        let dy = (CGFloat(y) - size.height / 2) / (size.height / 2)
                        value = min(1, max(0, 0.72 - (dx * dx + dy * dy) * 0.45))
                    case .highFrequency:
                        value = (x * 13 + y * 17).isMultiple(of: 5) ? 0 : 1
                    case .mostlyDark:
                        value = (x + y).isMultiple(of: 11) ? 0.75 : 0.15
                    case .mostlyBright:
                        value = (x + y).isMultiple(of: 11) ? 0.25 : 0.9
                    }
                    UIColor(white: value, alpha: 1).setFill()
                    cg.fill(CGRect(x: x, y: y, width: 1, height: 1))
                }
            }
        }
    }
}
