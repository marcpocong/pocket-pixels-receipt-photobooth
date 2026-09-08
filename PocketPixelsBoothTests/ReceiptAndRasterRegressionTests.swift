import Foundation
import XCTest
import UIKit
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
