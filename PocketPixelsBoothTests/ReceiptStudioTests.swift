import XCTest
import UIKit
@testable import PocketPixelsBooth

@MainActor final class ReceiptStudioTests: XCTestCase {
    private func logo(_ size: CGSize) throws -> String {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.black.setFill(); context.fill(CGRect(origin: .zero, size: size))
        }
        return try EventHeaderAssetStore().importArtworkData(XCTUnwrap(image.pngData()))
    }

    func testReplacementPreservesOtherElementsAndOldArtworkAcrossAspectRatios() throws {
        var design = SavedEventDesign.new(name: "CIM INTRAMS", venue: "Cebu")
        let originalID = try logo(CGSize(width: 300, height: 300))
        design.replaceLogo(identifier: originalID)
        var header = ReceiptComposer.prepareCoBrandedEditing(design.profile.receiptHeader)
        header.coBrandedAdjustments?.studioScale = 0.75
        header = ReceiptComposer.moveHeaderElement(header, target: .studio, horizontal: -8, vertical: 12)
        header = ReceiptComposer.moveHeaderElement(header, target: .separator, horizontal: 8, vertical: 8)
        header = ReceiptComposer.moveHeaderElement(header, target: .whole, vertical: 8)
        header.scale = 0.7
        header.topSpacing = 16; header.bottomSpacing = 24
        header.cropZoom = 2; header.cropPositionX = 0.6
        design.profile.receiptHeader = header
        let before = try XCTUnwrap(ReceiptComposer.headerEditingPlan(header))
        for size in [CGSize(width: 1000, height: 100), CGSize(width: 100, height: 1000), CGSize(width: 300, height: 300)] {
            design.replaceLogo(identifier: try logo(size))
            let after = design.profile.receiptHeader
            let plan = try XCTUnwrap(ReceiptComposer.headerEditingPlan(after))
            XCTAssertEqual(plan.mastheadFrames, before.mastheadFrames)
            XCTAssertEqual(plan.coBrandSeparatorFrame, before.coBrandSeparatorFrame)
            XCTAssertEqual(after.coBrandedAdjustments?.studioScale, header.coBrandedAdjustments?.studioScale)
            XCTAssertEqual(after.coBrandedAdjustments?.compositionScale, header.coBrandedAdjustments?.compositionScale)
            XCTAssertEqual(after.topSpacing, 16); XCTAssertEqual(after.bottomSpacing, 24)
            XCTAssertEqual(after.scale, 0.7); XCTAssertEqual(after.brandingMode, .coBranded)
            XCTAssertEqual(after.cropZoom, 1); XCTAssertEqual(after.cropPositionX, 0)
            let event = try XCTUnwrap(plan.customHeaderFrame), cross = try XCTUnwrap(plan.coBrandSeparatorFrame)
            XCTAssertGreaterThanOrEqual(event.minX, cross.maxX + 7.9)
            XCTAssertLessThanOrEqual(event.maxX, 540.01)
        }
        XCTAssertNotNil(try EventHeaderAssetStore().loadArtwork(identifier: originalID), "Frozen receipts retain the previous artwork")
        let restored = try JSONDecoder().decode(SavedEventDesign.self, from: JSONEncoder().encode(design))
        XCTAssertEqual(restored, design)
    }

    func testCompatibleReplacementKeepsCropAndOnlyIncompatibleArtworkResetsIt() throws {
        var design = SavedEventDesign.new(name: "CIM", venue: "")
        design.replaceLogo(identifier: try logo(CGSize(width: 300, height: 180)))
        design.profile.receiptHeader.layoutMode = .fill
        design.profile.receiptHeader.cropZoom = 2
        design.profile.receiptHeader.cropPositionX = 0.4
        design.profile.receiptHeader.cropPositionY = -0.4
        design.replaceLogo(identifier: try logo(CGSize(width: 600, height: 360)))
        XCTAssertEqual(design.profile.receiptHeader.cropZoom, 2)
        XCTAssertEqual(design.profile.receiptHeader.cropPositionX, 0.4)
        XCTAssertEqual(design.profile.receiptHeader.cropPositionY, -0.4)
        design.replaceLogo(identifier: try logo(CGSize(width: 180, height: 300)))
        XCTAssertEqual(design.profile.receiptHeader.cropZoom, 1)
        XCTAssertEqual(design.profile.receiptHeader.cropPositionX, 0)
        XCTAssertEqual(design.profile.receiptHeader.layoutMode, .fill)
    }

    func testFirstLogoUsesRecommendedHeaderWithoutChangingOtherEventSettings() throws {
        var design = SavedEventDesign.new(name: "CIM INTRAMS", venue: "Cebu")
        design.profile = RegularBoothSettings().profile
        design.profile.receiptDesign.editorialCaption = "CIM"
        design.replaceLogo(identifier: try logo(CGSize(width: 300, height: 180)))
        XCTAssertEqual(design.layout, .coBranded)
        XCTAssertEqual(design.profile.receiptHeader.topSpacing, ReceiptHeaderConfiguration.coBrandedRecommended.topSpacing)
        XCTAssertEqual(design.profile.receiptDesign.editorialCaption, "CIM")
        XCTAssertTrue(design.personalizeReceipt)
    }

    func testReplacementPreservesOtherBrandingModes() throws {
        for mode in ReceiptBrandingMode.allCases {
            var design = SavedEventDesign.new(name: "Mode", venue: "")
            design.replaceLogo(identifier: try logo(CGSize(width: 200, height: 100)))
            design.profile.receiptHeader.brandingMode = mode
            design.profile.receiptHeader.scale = 0.8
            design.profile.receiptHeader.topSpacing = 28
            design.replaceLogo(identifier: try logo(CGSize(width: 100, height: 200)))
            XCTAssertEqual(design.layout, mode)
            XCTAssertEqual(design.profile.receiptHeader.scale, 0.8)
            XCTAssertEqual(design.profile.receiptHeader.topSpacing, 28)
        }
    }

    func testFitWidthFocusZoomAndRenderingNeverMutateReceiptBytes() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 576, height: 4000), format: format).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 576, height: 4000))
        }
        let bytes = image.pngData()
        let view = ReceiptZoomScrollView(frame: CGRect(x: 0, y: 0, width: 330, height: 700))
        view.sizing = .fitWidth
        view.display(image, rendering: .exactRaster); view.layoutIfNeeded()
        XCTAssertEqual(view.imageView.frame.width, 330, accuracy: 0.1)
        XCTAssertGreaterThan(view.contentSize.height, 700)
        XCTAssertTrue(view.panGestureRecognizer.isEnabled)
        XCTAssertEqual(view.imageView.layer.magnificationFilter, .nearest)
        view.setFocus(.footer); view.layoutIfNeeded()
        XCTAssertEqual(view.contentOffset.y, view.contentSize.height - 700, accuracy: 0.5)
        view.zoom(toRelative: 2, animated: false)
        XCTAssertEqual(view.zoomScale, view.fitScale * 2, accuracy: 0.01)
        view.setFocus(.header); view.layoutIfNeeded()
        XCTAssertEqual(view.contentOffset.y, 0, accuracy: 0.1)
        XCTAssertEqual(view.zoomScale, view.fitScale, accuracy: 0.01)
        view.display(image, rendering: .smooth); view.layoutIfNeeded()
        XCTAssertEqual(view.imageView.layer.magnificationFilter, .linear)
        XCTAssertEqual(image.pngData(), bytes)
    }
}
