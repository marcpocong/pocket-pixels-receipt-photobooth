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

    func testCaptionWithDerivedEnableFlagIsOneUndoAndRestoresFlagOnRedo() {
        let initial = SavedEventDesign.new(name: "Caption", venue: "")
        var history = ReceiptStudioHistory(), value = initial
        let time = Date()
        for (index, caption) in ["K", "Ke", "Keep"].enumerated() {
            var next = value
            next.profile.receiptDesign.editorialCaption = caption
            next.profile.receiptExtrasEnabled = true
            history.record(from: value, to: next, now: time.addingTimeInterval(Double(index) / 10))
            value = next
        }
        XCTAssertEqual(history.undoValues.count, 1)
        let edited = value
        value = history.undo(value); XCTAssertEqual(value, initial)
        value = history.redo(value); XCTAssertEqual(value, edited)
    }

    func testReceiptSaveMergesOnlyEditedFieldsWithoutReplacingNewCommercialOrGuestData() {
        let original = SavedEventDesign.new(name: "Original", venue: "")
        var draft = original
        draft.profile.receiptDesign.editorialCaption = "Our keepsake"
        draft.profile.receiptExtrasEnabled = true
        var latest = original
        latest.serverEvents = ["live:synthetic": "new-commercial-binding"]
        latest.name = "Renamed in Setup"
        latest.profile.customerWelcomeMessage = "New guest settings"
        latest.profile.galleryReceiptStyleOverride = GalleryReceiptStyle.allCases.last
        latest.profile.location = "New setup location"
        latest.applyReceiptEdits(from: draft, baseline: original)
        XCTAssertEqual(latest.serverEvents, ["live:synthetic": "new-commercial-binding"])
        XCTAssertEqual(latest.name, "Renamed in Setup")
        XCTAssertEqual(latest.profile.customerWelcomeMessage, "New guest settings")
        XCTAssertEqual(latest.profile.location, "New setup location", "Unedited receipt fields keep the latest parent value")
        XCTAssertEqual(latest.profile.receiptDesign.editorialCaption, "Our keepsake")
        XCTAssertEqual(latest.profile.receiptExtrasEnabled, true)
        let committed = latest
        latest.applyReceiptEdits(from: SavedEventDesign.new(name: "Other", venue: ""), baseline: original)
        XCTAssertEqual(latest, committed, "Another design's draft cannot replace this design")
    }

    func testScaleAndExternalLogoMergeThenPersistAcrossReopen() throws {
        let original = SavedEventDesign.new(name: "Merge", venue: "")
        var local = original, latest = original
        local.profile.receiptHeader.scale = 0.7
        latest.profile.receiptHeader.assetIdentifier = "new-external-logo"
        latest.serverEvents = ["live:synthetic": "binding"]
        XCTAssertTrue(latest.applyReceiptEdits(from: local, baseline: original).isEmpty)
        let reopened = try JSONDecoder().decode(SavedEventDesign.self, from: JSONEncoder().encode(latest))
        XCTAssertEqual(reopened.profile.receiptHeader.scale, 0.7)
        XCTAssertEqual(reopened.logoIdentifier, "new-external-logo")
        XCTAssertEqual(reopened.serverEvents, latest.serverEvents)
    }

    func testLocalLogoAndExternalSpacingAndNestedAdjustmentsMerge() {
        var original = SavedEventDesign.new(name: "Merge", venue: "")
        original.profile.receiptHeader.coBrandedAdjustments = CoBrandedHeaderAdjustments(configuration: .coBrandedRecommended)
        var local = original, latest = original
        local.profile.receiptHeader.assetIdentifier = "local-logo"
        local.profile.receiptHeader.coBrandedAdjustments?.studioScale = 0.8
        latest.profile.receiptHeader.bottomSpacing = 33
        latest.profile.receiptHeader.coBrandedAdjustments?.eventY = 12
        XCTAssertTrue(latest.applyReceiptEdits(from: local, baseline: original).isEmpty)
        XCTAssertEqual(latest.logoIdentifier, "local-logo")
        XCTAssertEqual(latest.profile.receiptHeader.bottomSpacing, 33)
        XCTAssertEqual(latest.profile.receiptHeader.coBrandedAdjustments?.studioScale, 0.8)
        XCTAssertEqual(latest.profile.receiptHeader.coBrandedAdjustments?.eventY, 12)
    }

    func testConflictBlocksEntireSaveAndUndoAllowsSafeRetryAcrossSections() {
        let original = SavedEventDesign.new(name: "Conflict", venue: "")
        var local = original, latest = original, history = ReceiptStudioHistory()
        local.profile.receiptHeader.scale = 0.7
        history.record(from: original, to: local); history.endGroup() // changing sections
        let headerEdit = local
        local.profile.receiptDesign.editorialCaption = "Footer edit"
        history.record(from: headerEdit, to: local)
        latest.profile.receiptHeader.scale = 0.9
        latest.name = "Concurrent setup"
        let external = latest
        XCTAssertEqual(latest.applyReceiptEdits(from: local, baseline: original), ["Header.scale"])
        XCTAssertEqual(latest, external, "A conflicting save must not partially commit other sections")
        local = history.undo(local); local = history.undo(local)
        XCTAssertTrue(latest.applyReceiptEdits(from: local, baseline: original).isEmpty)
        XCTAssertEqual(latest, external)
        local = history.redo(local)
        XCTAssertEqual(latest.applyReceiptEdits(from: local, baseline: original), ["Header.scale"])
        XCTAssertEqual(latest, external, "Redo must not bypass conflict detection")
    }

    func testSameValueConcurrentEditIsNotConflictAndOptionalRemovalIsPreserved() {
        var original = SavedEventDesign.new(name: "Optional", venue: "")
        original.profile.receiptHeader.assetIdentifier = "old-logo"
        var local = original, latest = original
        local.profile.receiptHeader.scale = 0.8
        latest.profile.receiptHeader.scale = 0.8
        latest.profile.receiptHeader.assetIdentifier = nil
        XCTAssertTrue(latest.applyReceiptEdits(from: local, baseline: original).isEmpty)
        XCTAssertNil(latest.logoIdentifier)
        XCTAssertEqual(latest.profile.receiptHeader.scale, 0.8)
    }

    func testSimultaneousGeometryInitializationOrResetConflictsWithoutGuessing() {
        let original = SavedEventDesign.new(name: "Geometry", venue: "")
        var local = original, latest = original
        local.profile.receiptHeader.coBrandedAdjustments = CoBrandedHeaderAdjustments(configuration: .coBrandedRecommended)
        latest.profile.receiptHeader.coBrandedAdjustments = CoBrandedHeaderAdjustments(configuration: .coBrandedRecommended)
        latest.profile.receiptHeader.coBrandedAdjustments?.studioY = 20
        let external = latest
        XCTAssertEqual(latest.applyReceiptEdits(from: local, baseline: original), ["Header.coBrandedAdjustments"])
        XCTAssertEqual(latest, external)
    }

    func testImportBlocksSaveUntilCompletionAndRejectsDuplicateThenReopensSavedLogo() async throws {
        let session = ReceiptArtworkImportSession()
        let gate = ArtworkImportGate()
        let original = SavedEventDesign.new(name: "Import", venue: "")
        var local = original, parent = original
        let image = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 30)).image { ctx in
            UIColor.black.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        }
        let imported = try await EventArtworkImporter.importData(XCTUnwrap(image.pngData()))
        XCTAssertTrue(session.begin { try await gate.wait() })
        XCTAssertFalse(session.begin { imported })
        let task = Task { await session.process { local.replaceLogo(identifier: $0.identifier) } }
        await gate.waitUntilStarted()
        XCTAssertTrue(session.isImporting)
        XCTAssertEqual(session.save(local, baseline: original, into: &parent), ["Logo is still importing"])
        XCTAssertEqual(parent, original)
        gate.finish(.success(imported)); await task.value
        XCTAssertFalse(session.isImporting); XCTAssertNil(session.errorMessage)
        XCTAssertTrue(session.save(local, baseline: original, into: &parent).isEmpty)
        let reopened = try JSONDecoder().decode(SavedEventDesign.self, from: JSONEncoder().encode(parent))
        XCTAssertEqual(reopened.logoIdentifier, imported.identifier)
        XCTAssertNotNil(try EventHeaderAssetStore().loadArtwork(identifier: reopened.logoIdentifier))
    }

    func testImportFailureKeepsExistingLogoAndReportsFailure() async {
        let session = ReceiptArtworkImportSession()
        var local = SavedEventDesign.new(name: "Failure", venue: "")
        local.profile.receiptHeader.assetIdentifier = "existing-logo"
        let before = local
        session.begin { throw EventArtworkImporter.ImportError.noFile }
        await session.process { local.replaceLogo(identifier: $0.identifier) }
        XCTAssertEqual(local, before); XCTAssertFalse(session.isImporting)
        XCTAssertEqual(session.errorMessage, EventArtworkImporter.ImportError.noFile.localizedDescription)
    }

    func testCancelDuringImportPreventsLateDraftOrParentMutationAndRetainsArtwork() async throws {
        let session = ReceiptArtworkImportSession(), gate = ArtworkImportGate()
        var local = SavedEventDesign.new(name: "Cancel", venue: "")
        let original = local
        var parent = local
        parent.name = "Concurrent Setup change"
        parent.serverEvents = ["live:synthetic": "new-binding"]
        parent.profile.receiptHeader.assetIdentifier = "new-external-logo"
        let external = parent
        let image = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20)).image { ctx in
            UIColor.black.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        }
        let imported = try await EventArtworkImporter.importData(XCTUnwrap(image.pngData()))
        session.begin { try await gate.wait() }
        let task = Task { await session.process { local.replaceLogo(identifier: $0.identifier) } }
        await gate.waitUntilStarted()
        session.close(); task.cancel()
        gate.finish(.success(imported)); await task.value
        XCTAssertEqual(local, original); XCTAssertFalse(session.isImporting)
        XCTAssertEqual(session.save(local, baseline: original, into: &parent), ["Editing session is closed"])
        XCTAssertEqual(parent, external, "Cancel preserves concurrent Setup updates and cannot commit a late result")
        XCTAssertFalse(session.begin { imported }, "A dismissed session cannot accept new imports")
        XCTAssertNotNil(try EventHeaderAssetStore().loadArtwork(identifier: imported.identifier))
    }

    func testCancelledImportCannotOverwriteLaterReplacementOrRemoval() async throws {
        let session = ReceiptArtworkImportSession(), gate = ArtworkImportGate()
        var local = SavedEventDesign.new(name: "Replacement", venue: "")
        local.profile.receiptHeader.assetIdentifier = "existing-logo"
        let image = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20)).image { _ in }
        let artwork = EventArtwork(image: image)
        let old = EventArtworkImporter.Imported(identifier: "late-old-import", artwork: artwork)
        let new = EventArtworkImporter.Imported(identifier: "chosen-replacement", artwork: artwork)
        session.begin { try await gate.wait() }
        let first = Task { await session.process { local.replaceLogo(identifier: $0.identifier) } }
        await gate.waitUntilStarted()
        session.cancelImport()
        session.begin { new }
        await session.process { local.replaceLogo(identifier: $0.identifier) }
        XCTAssertEqual(local.logoIdentifier, new.identifier)
        local.profile.receiptHeader.assetIdentifier = nil; local.personalizeReceipt = false
        gate.finish(.success(old)); await first.value
        XCTAssertNil(local.logoIdentifier); XCTAssertFalse(local.personalizeReceipt)
        XCTAssertFalse(session.isImporting)
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
        view.preservesViewportOnImageChange = true
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

/// Deterministic provider completion; no timing delays or network services.
@MainActor private final class ArtworkImportGate {
    private var continuation: CheckedContinuation<EventArtworkImporter.Imported, Error>?
    private var started: CheckedContinuation<Void, Never>?
    func wait() async throws -> EventArtworkImporter.Imported {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation; started?.resume(); started = nil
        }
    }
    func waitUntilStarted() async {
        if continuation != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func finish(_ result: Result<EventArtworkImporter.Imported, Error>) {
        continuation?.resume(with: result); continuation = nil
    }
}
