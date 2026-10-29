import XCTest
import UIKit
@testable import PocketPixelsBooth

@MainActor final class ReceiptStudioV2Tests: XCTestCase {
    func testHistoryCoalescesContinuousValuesAndPreservesAllSections() throws {
        let initial = SavedEventDesign.new(name: "History", venue: "")
        var value = initial, history = ReceiptStudioHistory()
        let now = Date()
        for index in 1...10 {
            var next = value; next.profile.receiptHeader.scale = 0.5 + Double(index) / 100
            history.record(from: value, to: next, now: now.addingTimeInterval(Double(index) / 100)); value = next
        }
        XCTAssertEqual(history.undoValues.count, 1)
        let sized = value
        history.endGroup()
        var caption = value; caption.profile.receiptDesign.editorialCaption = "Keep this"
        history.record(from: value, to: caption); value = caption
        XCTAssertEqual(history.undoValues.count, 2)
        value = history.undo(value); XCTAssertEqual(value, sized)
        value = history.undo(value); XCTAssertEqual(value, initial)
        value = history.redo(value); XCTAssertEqual(value, sized)
        value = history.redo(value); XCTAssertEqual(value, caption)
        value = history.undo(value)
        var changed = value; changed.profile.location = "Cebu"
        history.record(from: value, to: changed)
        XCTAssertFalse(history.canRedo)
        XCTAssertEqual(try JSONDecoder().decode(SavedEventDesign.self, from: JSONEncoder().encode(caption)), caption)
    }

    func testHistoryIgnoresNoOpsAndBoundsRetainedValues() {
        var value = SavedEventDesign.new(name: "Bounded", venue: ""), history = ReceiptStudioHistory()
        history.record(from: value, to: value); XCTAssertFalse(history.canUndo)
        for i in 0..<100 {
            var next = value; next.profile.location = String(i)
            history.endGroup(); history.record(from: value, to: next); value = next
        }
        XCTAssertEqual(history.undoValues.count, 60)
    }

    func testPortraitColumnsAndFocusedFallback() {
        XCTAssertTrue(ReceiptStudioLayout.usesColumns(width: 834))
        let preview = ReceiptStudioLayout.previewWidth(for: 834)
        XCTAssertGreaterThan(preview, 450)
        XCTAssertGreaterThanOrEqual(834 - 53 - preview, 290)
        XCTAssertFalse(ReceiptStudioLayout.usesColumns(width: 600))
        XCTAssertTrue(ReceiptStudioLayout.usesColumns(width: 720))
    }

    func testWholeReceiptViewportPreservesManualZoomPanAndSelectionAcrossEdits() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 576, height: 4000), format: format).image { _ in }
        let view = ReceiptZoomScrollView(frame: CGRect(x: 0, y: 0, width: 470, height: 720))
        view.display(image, rendering: .smooth); view.layoutIfNeeded()
        XCTAssertEqual(view.fitScale, 720 / 4000, accuracy: 0.001)
        XCTAssertLessThanOrEqual(view.contentSize.height, 720.1)
        view.zoom(toRelative: 3, animated: false); view.contentOffset.y = 140
        let zoom = view.zoomScale, offset = view.contentOffset
        for target in CoBrandedHeaderTarget.allCases {
            view.selectedElement = target
            view.showsSelection.toggle()
            view.display(image, rendering: .exactRaster); view.setFocus(.full); view.layoutIfNeeded()
            XCTAssertEqual(view.zoomScale, zoom, accuracy: 0.001)
            XCTAssertEqual(view.contentOffset.y, offset.y, accuracy: 0.1)
        }
        view.frame.size = CGSize(width: 600, height: 500); view.layoutIfNeeded()
        XCTAssertEqual(view.zoomScale / view.fitScale, 3, accuracy: 0.01)
        view.fit(.fitWidth); view.layoutIfNeeded()
        XCTAssertEqual(view.contentSize.width, 600, accuracy: 0.1)
        view.fit(.wholeReceipt); view.layoutIfNeeded()
        XCTAssertEqual(view.contentSize.height, 500, accuracy: 0.1)
    }

    func testPrecisionRecenterResetAndPrintableBounds() throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 180)).image { context in
            UIColor.black.setFill(); context.fill(CGRect(x: 0, y: 0, width: 300, height: 180))
        }
        var config = ReceiptHeaderConfiguration.coBrandedRecommended
        config.assetIdentifier = try EventHeaderAssetStore().importArtworkData(XCTUnwrap(image.pngData()))
        config = ReceiptComposer.prepareCoBrandedEditing(config)
        config.coBrandedAdjustments?.compositionScale = 0.7
        for precision in ReceiptMovementPrecision.allCases {
            let before = ReceiptEditorGeometry(plan: try XCTUnwrap(ReceiptComposer.headerEditingPlan(config))).header
            let moved = ReceiptComposer.moveHeaderElement(config, target: .whole, vertical: precision.dots)
            let after = ReceiptEditorGeometry(plan: try XCTUnwrap(ReceiptComposer.headerEditingPlan(moved))).header
            XCTAssertEqual(after.midY - before.midY, precision.dots, accuracy: 0.2)
        }
        for target in CoBrandedHeaderTarget.allCases {
            let moved = ReceiptComposer.moveHeaderElement(config, target: target, horizontal: 10000, vertical: -10000)
            let geometry = ReceiptEditorGeometry(plan: try XCTUnwrap(ReceiptComposer.headerEditingPlan(moved)))
            XCTAssertGreaterThanOrEqual(geometry.header.minX, 35.9)
            XCTAssertLessThanOrEqual(geometry.header.maxX, 540.1)
            let centered = ReceiptComposer.recenterHeaderElement(moved, target: target)
            XCTAssertEqual(centered.scale, moved.scale)
            XCTAssertEqual(centered.coBrandedAdjustments?.compositionScale, moved.coBrandedAdjustments?.compositionScale)
            XCTAssertEqual(centered.assetIdentifier, config.assetIdentifier)
        }
        let centered = ReceiptComposer.recenterHeaderElement(config, target: .whole)
        let reset = ReceiptComposer.resetHeaderElement(config, target: .whole)
        XCTAssertNotEqual(centered, reset)
        XCTAssertEqual(reset.assetIdentifier, config.assetIdentifier)
        XCTAssertNil(reset.coBrandedAdjustments)
        XCTAssertNotNil(try EventHeaderAssetStore().loadArtwork(identifier: XCTUnwrap(config.assetIdentifier)))
    }
}
