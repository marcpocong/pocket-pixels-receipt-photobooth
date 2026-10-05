import Foundation
import UIKit
import XCTest
@testable import PocketPixelsBooth

final class EventHeaderTests: XCTestCase {
    func testLegacyEventProfileDecodesWithDefaultHeader() throws {
        let profile = makeProfile()
        let encoded = try JSONEncoder().encode(profile)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "receiptHeader")
        object.removeValue(forKey: "showEventTextBlock")

        let decoded = try JSONDecoder().decode(EventProfile.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(decoded.receiptHeader, .default)
        XCTAssertTrue(decoded.showEventTextBlock)
    }

    func testDefaultAndNoHeaderGeometry() throws {
        let defaultPlan = try ReceiptComposer.makeLayoutPlan(format: .duo, eventProfile: makeProfile())
        var noHeader = makeProfile()
        noHeader.receiptHeader.mode = .none
        let noHeaderPlan = try ReceiptComposer.makeLayoutPlan(format: .duo, eventProfile: noHeader)

        XCTAssertEqual(defaultPlan.headerMode, .pocketPixelsDefault)
        XCTAssertEqual(noHeaderPlan.headerMode, .none)
        XCTAssertLessThan(noHeaderPlan.photoFrames[0].rect.minY, defaultPlan.photoFrames[0].rect.minY)
        XCTAssertNil(noHeaderPlan.customHeaderFrame)
    }

    func testCustomHeaderAppearsWithinSafeRegionAndPreservesAspectRatio() throws {
        let identifier = try EventHeaderAssetStore().importImageData(makeImage(size: CGSize(width: 800, height: 200), color: .black).pngData()!)
        var profile = makeProfile()
        profile.receiptHeader.mode = .customEventHeader
        profile.receiptHeader.assetIdentifier = identifier
        let plan = try ReceiptComposer.makeLayoutPlan(format: .solo, eventProfile: profile)
        let frame = try XCTUnwrap(plan.customHeaderFrame)

        XCTAssertEqual(plan.headerMode, .customEventHeader)
        XCTAssertLessThanOrEqual(frame.height, EventHeaderImageProcessor.maximumPrintedHeight)
        XCTAssertGreaterThan(frame.width, frame.height)
        XCTAssertGreaterThanOrEqual(frame.minX, EventHeaderImageProcessor.horizontalInset)
        XCTAssertLessThanOrEqual(frame.maxX, CGFloat(BoothConfiguration.receiptWidth) - EventHeaderImageProcessor.horizontalInset)

        profile.showEventTextBlock = false
        let receipt = try ReceiptComposer.compose(
            photos: [ReliabilityFixtures.syntheticPhoto(session: 400, photo: 1, format: .solo)],
            sessionIdentifier: "PP-CUSTOM-HEADER",
            format: .solo,
            eventProfile: profile
        )
        let receiptImage = try XCTUnwrap(UIImage(data: receipt.imagePNGData))
        let centerPixel = try rgbaPixel(in: receiptImage, x: Int(frame.midX), y: Int(frame.midY))
        XCTAssertLessThan(centerPixel.0, 20)
        XCTAssertLessThan(centerPixel.1, 20)
        XCTAssertLessThan(centerPixel.2, 20)
    }

    func testExtremelyTallHeaderIsCapped() {
        let config = ReceiptHeaderConfiguration.default
        let size = EventHeaderImageProcessor.frameSize(sourceSize: CGSize(width: 100, height: 2_000), configuration: config)
        XCTAssertEqual(size.height, EventHeaderImageProcessor.maximumPrintedHeight)
    }

    func testCustomHeaderKeepsEveryReceiptFormatWithinMaximumHeight() throws {
        let identifier = try EventHeaderAssetStore().importImageData(makeImage(size: CGSize(width: 100, height: 2_000), color: .black).pngData()!)
        var profile = makeProfile()
        profile.receiptHeader.mode = .customEventHeader
        profile.receiptHeader.assetIdentifier = identifier
        profile.receiptHeader.scale = ReceiptHeaderConfiguration.maximumScale
        profile.receiptHeader.topSpacing = ReceiptHeaderConfiguration.maximumSpacing
        profile.receiptHeader.bottomSpacing = ReceiptHeaderConfiguration.maximumSpacing
        for format in BoothFormat.allCases {
            let plan = try ReceiptComposer.makeLayoutPlan(format: format, eventProfile: profile)
            XCTAssertLessThanOrEqual(plan.height, BoothConfiguration.receiptMaximumHeight)
            XCTAssertLessThanOrEqual(try XCTUnwrap(plan.customHeaderFrame).height, EventHeaderImageProcessor.maximumPrintedHeight)
        }
    }

    func testTransparentPNGCompositesAgainstWhite() throws {
        let source = makeTransparentMark()
        let rendered = EventHeaderImageProcessor.renderedHeader(source: source, configuration: .default).image
        let pixel = try rgbaPixel(in: rendered, x: 0, y: 0)
        XCTAssertEqual(pixel.0, 255)
        XCTAssertEqual(pixel.1, 255)
        XCTAssertEqual(pixel.2, 255)
        XCTAssertEqual(pixel.3, 255)
    }

    func testAlignmentProducesDeterministicFrames() throws {
        let identifier = try EventHeaderAssetStore().importImageData(makeImage(size: CGSize(width: 600, height: 120), color: .black).pngData()!)
        var profile = makeProfile()
        profile.receiptHeader.mode = .customEventHeader
        profile.receiptHeader.assetIdentifier = identifier
        profile.receiptHeader.scale = 0.7

        profile.receiptHeader.alignment = .left
        let left = try XCTUnwrap(ReceiptComposer.makeLayoutPlan(format: .solo, eventProfile: profile).customHeaderFrame)
        profile.receiptHeader.alignment = .center
        let center = try XCTUnwrap(ReceiptComposer.makeLayoutPlan(format: .solo, eventProfile: profile).customHeaderFrame)
        profile.receiptHeader.alignment = .right
        let right = try XCTUnwrap(ReceiptComposer.makeLayoutPlan(format: .solo, eventProfile: profile).customHeaderFrame)

        XCTAssertLessThan(left.minX, center.minX)
        XCTAssertLessThan(center.minX, right.minX)
        XCTAssertEqual(left.width, center.width)
        XCTAssertEqual(center.width, right.width)
    }

    func testFitFillAndCropSettingsAreDeterministicAndCodable() throws {
        let source = makeImage(size: CGSize(width: 500, height: 100), color: .black)
        var fit = ReceiptHeaderConfiguration.default
        fit.layoutMode = .fit
        let fitResult = EventHeaderImageProcessor.renderedHeader(source: source, configuration: fit)
        var fill = fit
        fill.layoutMode = .fill
        let unzoomedFill = EventHeaderImageProcessor.renderedHeader(source: source, configuration: fill)
        fill.cropPositionX = 0.45
        fill.cropPositionY = -0.3
        fill.cropZoom = 1.8
        let first = EventHeaderImageProcessor.renderedHeader(source: source, configuration: fill)
        let second = EventHeaderImageProcessor.renderedHeader(source: source, configuration: fill)

        XCTAssertGreaterThan(unzoomedFill.sourceDrawRect.width, fitResult.sourceDrawRect.width)
        XCTAssertGreaterThan(first.sourceDrawRect.width, unzoomedFill.sourceDrawRect.width)
        XCTAssertEqual(first.sourceDrawRect, second.sourceDrawRect)
        let roundTrip = try JSONDecoder().decode(ReceiptHeaderConfiguration.self, from: JSONEncoder().encode(fill))
        XCTAssertEqual(roundTrip, fill)
    }

    func testEventTextBlockCanBeRemovedWithoutReservedHeight() throws {
        var shown = makeProfile()
        shown.showEventTextBlock = true
        var hidden = shown
        hidden.showEventTextBlock = false
        let shownPlan = try ReceiptComposer.makeLayoutPlan(format: .duo, eventProfile: shown)
        let hiddenPlan = try ReceiptComposer.makeLayoutPlan(format: .duo, eventProfile: hidden)

        XCTAssertTrue(shownPlan.showsEventTextBlock)
        XCTAssertFalse(hiddenPlan.showsEventTextBlock)
        XCTAssertLessThan(hiddenPlan.photoFrames[0].rect.minY, shownPlan.photoFrames[0].rect.minY)
    }

    func testMissingAssetFallsBackToDefaultHeader() throws {
        var profile = makeProfile()
        profile.receiptHeader.mode = .customEventHeader
        profile.receiptHeader.assetIdentifier = UUID().uuidString.lowercased()
        let plan = try ReceiptComposer.makeLayoutPlan(format: .solo, eventProfile: profile)
        XCTAssertEqual(plan.headerMode, .pocketPixelsDefault)
        XCTAssertNil(plan.customHeaderFrame)
    }

    func testThermalPreviewIsDeterministic() throws {
        let source = makeTransparentMark()
        let first = try EventHeaderImageProcessor.thermalPreview(source: source, configuration: .default)
        let second = try EventHeaderImageProcessor.thermalPreview(source: source, configuration: .default)
        XCTAssertEqual(first.pngData(), second.pngData())
    }

    func testQualityAnalyzerFindsBroadWarningClasses() {
        let dark = makeImage(size: CGSize(width: 80, height: 400), color: UIColor(white: 0.05, alpha: 1))
        let warnings = EventHeaderImageProcessor.qualityWarnings(for: dark, configuration: .default)
        XCTAssertTrue(warnings.contains(.lowResolution))
        XCTAssertTrue(warnings.contains(.veryDark))
        XCTAssertTrue(warnings.contains(.veryTall))
        XCTAssertTrue(warnings.contains(.fineDetails))
        XCTAssertTrue(warnings.contains(.lowContrast))
    }

    func testImmutableAssetsKeepSessionAIsolatedFromProfileReplacement() throws {
        let store = try EventHeaderAssetStore()
        let firstID = try store.importImageData(makeImage(size: CGSize(width: 100, height: 50), color: .black).pngData()!)
        var activeProfile = makeProfile()
        activeProfile.receiptHeader.mode = .customEventHeader
        activeProfile.receiptHeader.assetIdentifier = firstID
        let frozenSessionA = activeProfile

        let secondID = try store.importImageData(makeImage(size: CGSize(width: 100, height: 50), color: .red).pngData()!)
        activeProfile.receiptHeader.assetIdentifier = secondID

        XCTAssertEqual(frozenSessionA.receiptHeader.assetIdentifier, firstID)
        XCTAssertEqual(activeProfile.receiptHeader.assetIdentifier, secondID)
        XCTAssertNotNil(store.loadImage(identifier: firstID))
        XCTAssertNotEqual(store.loadImage(identifier: firstID)?.pngData(), store.loadImage(identifier: secondID)?.pngData())
    }

    private func makeProfile() -> EventProfile {
        EventProfile(
            isEnabled: true,
            eventName: "MARK & ANNA",
            subtitle: "OUR WEDDING",
            includeEventDate: true,
            eventDate: Date(timeIntervalSince1970: 1_793_000_000),
            location: "CEBU",
            shortMessage: "THANK YOU"
        )
    }

    private func makeImage(size: CGSize, color: UIColor) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }

    private func makeTransparentMark() -> UIImage {
        let size = CGSize(width: 240, height: 80)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.clear.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor.black.setFill()
            context.fill(CGRect(x: 80, y: 20, width: 80, height: 40))
        }
    }

    private func rgbaPixel(in image: UIImage, x: Int, y: Int) throws -> (UInt8, UInt8, UInt8, UInt8) {
        let cgImage = try XCTUnwrap(image.cgImage)
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cgImage, in: CGRect(x: -x, y: y - cgImage.height + 1, width: cgImage.width, height: cgImage.height))
        return (pixel[0], pixel[1], pixel[2], pixel[3])
    }
}
