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
    func testFocusedProductionGeometryZoomHitTestingAndManualViewportSurviveUpdates() async throws {
        var profile = EventProfile(isEnabled: true, eventName: "Studio acceptance", subtitle: "Our hosts", includeEventDate: true, eventDate: Date(timeIntervalSince1970: 1_789_155_660), location: "Cebu", shortMessage: "Keep this moment")
        profile.receiptHeader = .coBrandedRecommended
        profile.receiptHeader.assetIdentifier = try logo(CGSize(width: 300, height: 180))
        profile.showEventTextBlock = true
        let receipt = try await EventReceiptComposerPreview.makePreviewReceipt(profile: profile, format: .solo)
        let geometry = try XCTUnwrap(receipt.editorGeometry)
        let image = try XCTUnwrap(UIImage(data: receipt.imagePNGData))
        let bytes = image.pngData(), savedProfile = profile
        let view = ReceiptZoomScrollView(frame: CGRect(x: 0, y: 0, width: 340, height: 600))
        view.sizing = .fitWidth
        view.elementFrames = geometry.elements
        view.onSelectElement = { _ in }
        view.display(image, rendering: .exactRaster)
        view.layoutIfNeeded()
        for target in CoBrandedHeaderTarget.allCases {
            let region = try XCTUnwrap(geometry.region(focus: .header, target: target, textTarget: .all))
            view.selectedElement = target
            view.setFocus(.header, rect: region, identity: target.rawValue)
            view.layoutIfNeeded()
            XCTAssertGreaterThan(view.zoomScale, view.fitScale * 1.03, "Header must actually magnify")
            let rect = try XCTUnwrap(geometry.elements[target])
            XCTAssertTrue(view.imageView.convert(rect, to: view).intersects(view.bounds))
            if target != .whole {
                XCTAssertEqual(view.hitTarget(at: CGPoint(x: rect.midX, y: rect.midY)), target)
                // Native view conversion includes pan and zoom, without a parallel coordinate model.
                view.zoom(toRelative: 2, animated: false)
                view.contentOffset.y = 24
                let screenPoint = view.imageView.convert(CGPoint(x: rect.midX, y: rect.midY), to: view)
                XCTAssertEqual(view.hitTarget(at: view.convert(screenPoint, to: view.imageView)), target)
            }
        }
        let cross = try XCTUnwrap(geometry.elements[.separator])
        view.zoom(toRelative: 1, animated: false)
        XCTAssertEqual(view.hitTarget(at: CGPoint(x: cross.midX, y: cross.minY - 8)), .separator, "Small separator has a larger touch target")
        view.setFocus(.footer, rect: geometry.region(focus: .footer, target: .whole, textTarget: .all)); view.layoutIfNeeded()
        XCTAssertTrue(view.bounds.insetBy(dx: -1, dy: -1).contains(view.imageView.convert(geometry.footer, to: view)), "The complete footer, including date/time, fits the focus")
        var options = ReceiptPrintOptions.default
        options.footerStyle = .decorativeBarcodeOnly
        let barcode = try await EventReceiptComposerPreview.makePreviewReceipt(profile: profile, format: .solo, printOptions: options)
        let barcodeGeometry = try XCTUnwrap(barcode.editorGeometry)
        view.display(try XCTUnwrap(UIImage(data: barcode.imagePNGData)), rendering: .exactRaster)
        view.setFocus(.footer, rect: barcodeGeometry.region(focus: .footer, target: .whole, textTarget: .all), identity: barcodeGeometry.footerIdentity)
        view.layoutIfNeeded()
        XCTAssertTrue(view.bounds.insetBy(dx: -1, dy: -1).contains(view.imageView.convert(barcodeGeometry.footer, to: view)), "Changing footer layout reframes the complete printed footer")
        view.display(image, rendering: .exactRaster); view.layoutIfNeeded()
        for target in ReceiptTextFocus.allCases where target != .caption {
            let region = try XCTUnwrap(geometry.region(focus: .text, target: .whole, textTarget: target))
            XCTAssertFalse(region.isNull)
            view.setFocus(.text, rect: region, identity: target.rawValue); view.layoutIfNeeded()
            XCTAssertTrue(view.imageView.convert(region, to: view).intersects(view.bounds))
        }
        view.setFocus(.full); view.layoutIfNeeded()
        view.zoom(toRelative: 2, animated: false); view.contentOffset.y = 80
        let zoom = view.zoomScale, offset = view.contentOffset
        view.display(image, rendering: .smooth); view.setFocus(.full); view.layoutIfNeeded()
        XCTAssertEqual(view.zoomScale, zoom, accuracy: 0.001)
        XCTAssertEqual(view.contentOffset.y, offset.y, accuracy: 0.1)
        XCTAssertEqual(image.pngData(), bytes, "Guides, focusing and selection never alter raster bytes")
        XCTAssertEqual(profile, savedProfile, "Opening / focusing never normalizes saved geometry")
    }

    func testPreviewMetadataAndOpaqueSampleCanvasForAllFormats() async throws {
        for index in 0..<6 {
            let image = EventReceiptComposerPreview.makeSamplePhoto(index: index)
            let cg = try XCTUnwrap(image.cgImage)
            var pixels = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
            let context = try XCTUnwrap(CGContext(data: &pixels, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
            XCTAssertTrue(stride(from: 3, to: pixels.count, by: 4).allSatisfy { pixels[$0] == 255 }, "Entire sample canvas is opaque")
            // Outside the silhouette and label, both right corners must contain gradient, not blank paper.
            for y in [1, cg.height - 2] {
                let value = pixels[(y * cg.width + cg.width - 2) * 4]
                XCTAssertGreaterThan(value, 20); XCTAssertLessThan(value, 240, "No white triangular gradient endpoint")
            }
        }
        for format in BoothFormat.allCases {
            let receipt = try await EventReceiptComposerPreview.makePreviewReceipt(profile: .pocketPixelsDefault, format: format)
            let metadata = try XCTUnwrap(receipt.editorGeometry)
            XCTAssertFalse(metadata.footer.isNull)
            XCTAssertNil(metadata.region(focus: .text, target: .whole, textTarget: .message), "Unprinted text has no invented focus region")
            XCTAssertEqual(receipt.width, 576)
        }
    }

    func testEnabledMovesChangeOnlyRequestedIdentityAndResetKeepsArtwork() throws {
        var config = ReceiptHeaderConfiguration.coBrandedRecommended
        config.assetIdentifier = try logo(CGSize(width: 300, height: 180))
        config = ReceiptComposer.prepareCoBrandedEditing(config)
        config.coBrandedAdjustments?.compositionScale = 0.75
        config.coBrandedAdjustments?.studioScale = 0.75
        config.scale = 0.75
        for target in CoBrandedHeaderTarget.allCases {
            let before = ReceiptEditorGeometry(plan: try XCTUnwrap(ReceiptComposer.headerEditingPlan(config))).elements
            for vertical in [false, true] {
                let travel = ReceiptComposer.headerTravel(config, target: target, vertical: vertical)
                for amount in [-4.0, 4.0] where (amount < 0 ? travel.lowerBound < -0.5 : travel.upperBound > 0.5) {
                    let moved = ReceiptComposer.moveHeaderElement(config, target: target, horizontal: vertical ? 0 : amount, vertical: vertical ? amount : 0)
                    let after = ReceiptEditorGeometry(plan: try XCTUnwrap(ReceiptComposer.headerEditingPlan(moved))).elements
                    XCTAssertNotEqual(after[target], before[target], "Enabled arrow must move \(target)")
                    if target != .whole {
                        for other in [CoBrandedHeaderTarget.studio, .event, .separator] where other != target { XCTAssertEqual(after[other], before[other]) }
                    }
                }
            }
            let reset = ReceiptComposer.resetHeaderElement(config, target: target)
            XCTAssertEqual(reset.assetIdentifier, config.assetIdentifier)
            if target != .whole {
                let after = ReceiptEditorGeometry(plan: try XCTUnwrap(ReceiptComposer.headerEditingPlan(reset))).elements
                for other in [CoBrandedHeaderTarget.studio, .event, .separator] where other != target { XCTAssertEqual(after[other], before[other]) }
            }
        }
        let id = config.assetIdentifier
        config.resetEntireCoBrandedHeader()
        XCTAssertEqual(config.assetIdentifier, id)
    }

    func testSizeControlsExcludeClampedPlateausWithoutChangingNeighbors() throws {
        var config = ReceiptHeaderConfiguration.coBrandedRecommended
        config.assetIdentifier = try logo(CGSize(width: 300, height: 180))
        config = ReceiptComposer.prepareCoBrandedEditing(config)
        let untouched = config
        config.coBrandedAdjustments?.placement?.separatorX = 476
        let compressed = ReceiptComposer.headerSizeAvailability(config, target: .event, current: 1, maximum: 1)
        XCTAssertFalse(compressed.canResize, "An event logo clamped throughout the entire size range must have a disabled slider")
        config = untouched
        for target in CoBrandedHeaderTarget.allCases {
            let maximum = target == .separator ? 2.0 : 1.0
            let availability = ReceiptComposer.headerSizeAvailability(config, target: target, current: 1, maximum: maximum)
            guard availability.canResize else { continue }
            let before = ReceiptEditorGeometry(plan: try XCTUnwrap(ReceiptComposer.headerEditingPlan(config))).elements
            var resized = config
            switch target {
            case .whole: resized.coBrandedAdjustments?.compositionScale = 0.5
            case .studio: resized.coBrandedAdjustments?.studioScale = 0.5
            case .separator: resized.coBrandedAdjustments?.placement?.separatorScale = 0.5
            case .event: resized.scale = 0.5
            }
            let after = ReceiptEditorGeometry(plan: try XCTUnwrap(ReceiptComposer.headerEditingPlan(resized))).elements
            XCTAssertNotEqual(before[target]?.size, after[target]?.size)
            if target != .whole {
                for other in [CoBrandedHeaderTarget.studio, .separator, .event] where other != target { XCTAssertEqual(before[other], after[other]) }
            }
        }
        XCTAssertEqual(config, untouched, "Reading availability must not rewrite saved adjustments")
    }

}
