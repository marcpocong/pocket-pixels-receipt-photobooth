import ImageIO
import UIKit
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import PocketPixelsBooth

@MainActor
final class SamplePrintStudioTests: XCTestCase {
    private let openGate = SamplePrintStudioModel.PrinterGate(printerBusy: false, recoveryLocked: false, unresolvedPrint: false, guestSessionActive: false)

    // MARK: Policy

    func testEmptyStudioPreparesPlaceholderWithoutAPermanentLoadingIndicator() async throws {
        let model = makeModel()
        XCTAssertEqual(model.filledSlotCount, 0)
        XCTAssertFalse(model.showsPreviewLoadingIndicator)
        XCTAssertNotEqual(model.previewState, .idle, "Default settings must still start the placeholder render")
        try await waitForPreview(model)
        for mode in SampleReceiptPreviewMode.allCases {
            model.previewMode = mode
            XCTAssertNotNil(model.previewImage, "The numbered receipt placeholder is available in both modes")
            XCTAssertFalse(model.showsPreviewLoadingIndicator)
        }
        XCTAssertNil(model.printableSample)
        XCTAssertFalse(model.canPrint(openGate), "A placeholder must never become a printable guest photo")
    }

    func testRemovingAllPhotosReturnsToPlaceholderWithoutShowingPreviousPhotosOrASpinner() async throws {
        let model = makeModel()
        model.addImported([photo(0)])
        XCTAssertTrue(model.showsPreviewLoadingIndicator)
        try await waitForPreview(model)
        let importedPreview = try XCTUnwrap(model.currentPreview)
        model.removeAllPhotos()
        XCTAssertFalse(model.showsPreviewLoadingIndicator)
        XCTAssertNil(model.currentPreview, "Never reuse an imported photo while the empty placeholder prepares")
        XCTAssertFalse(model.canPrint(openGate))
        try await waitForPreview(model)
        XCTAssertNotNil(model.previewImage)
        XCTAssertNotEqual(model.currentPreview?.request, importedPreview.request)
        XCTAssertEqual(model.filledSlotCount, 0)
    }

    func testMountedDepartingSlotAndChooserSurviveShrinkingFormats() async throws {
        for populated in [false, true] {
            for original in [BoothFormat.duo, .gridSix, .passport] {
                let model = makeModel()
                model.setFormat(original)
                if populated { model.addImported((0..<original.photoCount).map(photo)) }
                let departingSlot = original.photoCount - 1
                let host = UIHostingController(rootView: VStack {
                    SampleSlotCard(model: model, index: departingSlot, choose: {})
                    SamplePhotoChooser(model: model, slot: departingSlot, dismiss: {})
                })
                let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
                let window = UIWindow(windowScene: scene)
                window.frame = CGRect(x: 0, y: 0, width: 834, height: 1194)
                window.rootViewController = host
                window.makeKeyAndVisible()
                defer { window.isHidden = true; window.rootViewController = nil }
                host.view.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(80))
                // Keep the departing views mounted, reproducing SwiftUI's stale-index update.
                model.setFormat(.solo)
                host.view.setNeedsLayout()
                host.view.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(80))
                XCTAssertEqual(model.slots.count, 1)
                XCTAssertNil(model.photoID(at: departingSlot))
                XCTAssertNil(model.photoID(at: -1))
                XCTAssertEqual(model.filledSlotCount, populated ? 1 : 0)
                let rendered = UIGraphicsImageRenderer(size: window.bounds.size).image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                XCTAssertNotNil(rendered.pngData())
            }
        }
    }

    func testPolicyBlocksGuestSessionsUnresolvedPrintsRecoveryAndDoubleTap() {
        XCTAssertTrue(SamplePrintPolicy.canStart(hasPreview: true, printerBusy: false, recoveryLocked: false, unresolvedPrint: false, operationActive: false, guestSessionActive: false))
        XCTAssertFalse(SamplePrintPolicy.canStart(hasPreview: false, printerBusy: false, recoveryLocked: false, unresolvedPrint: false, operationActive: false, guestSessionActive: false))
        XCTAssertFalse(SamplePrintPolicy.canStart(hasPreview: true, printerBusy: true, recoveryLocked: false, unresolvedPrint: false, operationActive: false, guestSessionActive: false))
        XCTAssertFalse(SamplePrintPolicy.canStart(hasPreview: true, printerBusy: false, recoveryLocked: true, unresolvedPrint: false, operationActive: false, guestSessionActive: false))
        XCTAssertFalse(SamplePrintPolicy.canStart(hasPreview: true, printerBusy: false, recoveryLocked: false, unresolvedPrint: true, operationActive: false, guestSessionActive: false))
        XCTAssertFalse(SamplePrintPolicy.canStart(hasPreview: true, printerBusy: false, recoveryLocked: false, unresolvedPrint: false, operationActive: true, guestSessionActive: false))
        XCTAssertFalse(SamplePrintPolicy.canStart(hasPreview: true, printerBusy: false, recoveryLocked: false, unresolvedPrint: false, operationActive: false, guestSessionActive: true))
        XCTAssertEqual(SamplePrintPolicy.clampedCopies(0), 1)
        XCTAssertEqual(SamplePrintPolicy.clampedCopies(9), SamplePrintPolicy.maximumCopies)
    }

    // MARK: Slots

    func testImportFillsSlotsInOrderWithoutSilentlyRepeatingAPhoto() {
        let model = makeModel()
        model.setFormat(.grid)
        let first = photo(0)
        model.addImported([first])
        XCTAssertEqual(model.slots, [first.id, nil, nil, nil])
        XCTAssertEqual(model.missingSlotCount, 3)
        XCTAssertFalse(model.request.isComplete)
        XCTAssertNotNil(model.blockedReason(openGate))

        let more = (1...3).map(photo)
        model.addImported(more)
        XCTAssertEqual(model.slots, [first.id] + more.map(\.id))
        XCTAssertTrue(model.request.isComplete)
    }

    func testExplicitDuplicateReplaceReorderClearAndRemove() {
        let model = makeModel()
        model.setFormat(.strip)
        let a = photo(0), b = photo(1)
        model.addImported([a, b])
        XCTAssertEqual(model.slots, [a.id, b.id, nil])

        model.duplicateIntoNextEmptySlot(0)
        XCTAssertEqual(model.slots, [a.id, b.id, a.id])
        XCTAssertEqual(model.usageCount(of: a.id), 2)

        model.moveSlot(0, by: 1)
        XCTAssertEqual(model.slots, [b.id, a.id, a.id])
        model.moveSlot(0, by: -1)
        XCTAssertEqual(model.slots, [b.id, a.id, a.id], "Moving past the first slot is ignored")

        model.assign(b.id, to: 2)
        XCTAssertEqual(model.slots, [b.id, a.id, b.id])

        model.clearSlot(1)
        XCTAssertEqual(model.slots, [b.id, nil, b.id])

        model.removeFromLibrary(b.id)
        XCTAssertEqual(model.slots, [nil, nil, nil])
        XCTAssertEqual(model.library.map(\.id), [a.id])
    }

    func testFormatChangeKeepsArrangementAndUsesOnlyUnusedPhotos() {
        let model = makeModel()
        model.setFormat(.gridSix)
        let photos = (0..<3).map(photo)
        model.addImported(photos)
        model.setFormat(.duo)
        XCTAssertEqual(model.slots, [photos[0].id, photos[1].id])
        model.setFormat(.grid)
        XCTAssertEqual(model.slots, [photos[0].id, photos[1].id, photos[2].id, nil])
    }

    func testTrayIsBounded() {
        let model = makeModel()
        model.addImported((0..<(SamplePrintPolicy.maximumImportedPhotos + 3)).map(photo))
        XCTAssertEqual(model.library.count, SamplePrintPolicy.maximumImportedPhotos)
        XCTAssertNotNil(model.status)
    }

    // MARK: Rendering

    func testEverySampleFormatPrintsWithoutSessionIdentifierOrQR() throws {
        for format in BoothFormat.allCases {
            let photos = (0..<format.photoCount).map { photo($0).image }
            let request = SamplePrintRequest(format: format, slotPhotoIDs: photos.map { _ in UUID() }, branding: .standard, eventProfile: nil, photoPass: format == .passport ? SamplePhotoPassDetails() : nil)
            let sample = try SamplePrintComposer.prepare(request: request, photos: photos, date: fixedDate, photoQualityProfile: .customerPrintDefault)
            XCTAssertFalse(sample.receipt.includesPrintedGalleryQR, format.rawValue)
            let composedImage = try XCTUnwrap(UIImage(data: sample.receipt.imagePNGData))
            let originalRaster = try ThermalImageRasterizer.rasterize(composedImage, purpose: .completeReceipt)
            XCTAssertEqual(sample.raster.rasterCommand, originalRaster.rasterCommand, "\(format): preserve production raster bytes")
            XCTAssertEqual(sample.raster.previewPNGData, originalRaster.previewPNGData)
            XCTAssertTrue(MonochromeReceiptRenderer.isSmoothMonochromePNG(sample.monochrome.pngData))
            XCTAssertEqual(sample.monochrome.width, sample.receipt.width)
            XCTAssertEqual(sample.monochrome.height, sample.receipt.height)
            for mode in SampleReceiptPreviewMode.allCases {
                let source = try XCTUnwrap(CGImageSourceCreateWithData(sample.pngData(for: mode) as CFData, nil))
                XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.png.identifier)
                let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
                XCTAssertEqual(image.width, sample.receipt.width)
                XCTAssertEqual(image.height, sample.receipt.height)
            }
            let grayImage = try XCTUnwrap(sample.monochrome.image.cgImage)
            let gray = try XCTUnwrap(grayImage.dataProvider?.data) as Data
            XCTAssertTrue(gray.contains { $0 > 20 && $0 < 235 }, "Smooth photo tones survive")

            let guest = try ReceiptComposer.compose(
                photos: photos, sessionIdentifier: "PP-20260907-161400", date: fixedDate, galleryURL: nil, format: format,
                passport: format == .passport ? SamplePhotoPassDetails().sessionData(configuration: .default) : nil,
                sampleGalleryPlaceholder: true
            )
            XCTAssertEqual(sample.receipt.height, guest.height, "\(format.rawValue): digital copies retain the normal receipt canvas")
            let samplePlan = try ReceiptComposer.makeLayoutPlan(format: format, includesGalleryQRCode: true, passport: format == .passport ? SamplePhotoPassDetails().sessionData(configuration: .default) : nil, date: fixedDate, printsSessionIdentifier: false)
            XCTAssertEqual(sample.receipt.height, samplePlan.height)
            XCTAssertGreaterThan(samplePlan.sessionIdentifierFrame.height, 0)

            // Digital samples retain breathing room but never print an invented session ID.
            let plan = try ReceiptComposer.makeLayoutPlan(format: format, includesGalleryQRCode: true, passport: format == .passport ? SamplePhotoPassDetails().sessionData(configuration: .default) : nil, date: fixedDate)
            let identifierBand = CGRect(x: 0, y: plan.sessionIdentifierFrame.minY, width: CGFloat(plan.width), height: plan.sessionIdentifierFrame.height)
            let sampleImage = try XCTUnwrap(UIImage(data: sample.receipt.imagePNGData)?.cgImage)
            let guestImage = try XCTUnwrap(UIImage(data: guest.imagePNGData)?.cgImage)
            XCTAssertEqual(darkPixels(in: sampleImage, rect: identifierBand), 0, "\(format.rawValue): sample must not expose a session ID")
            XCTAssertGreaterThan(darkPixels(in: guestImage, rect: identifierBand), 0, "\(format.rawValue): guest identifier band was not measured")
            let attachment = XCTAttachment(data: sample.raster.previewPNGData, uniformTypeIdentifier: UTType.png.identifier)
            attachment.name = "display-sample-\(format.rawValue)-thermal"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    func testSamplePrintPipelineKeepsCompactTopMarginAndPrintsFooterFirstWithoutExtraFeed() throws {
        for format in BoothFormat.allCases {
            for footer in ReceiptFooterStyle.allCases {
                let photos = (0..<format.photoCount).map { photo($0).image }
                let request = SamplePrintRequest(
                    format: format, slotPhotoIDs: photos.map { _ in UUID() },
                    branding: .standard, eventProfile: nil,
                    photoPass: format == .passport ? SamplePhotoPassDetails() : nil,
                    printOptions: ReceiptPrintOptions(footerStyle: footer)
                )
                let sample = try SamplePrintComposer.prepare(
                    request: request, photos: photos, date: fixedDate,
                    photoQualityProfile: .customerPrintDefault
                )
                let raster = sample.raster
                let firstInk = try XCTUnwrap((0..<raster.height).first { row in
                    raster.rasterData[(row * raster.widthBytes)..<((row + 1) * raster.widthBytes)].contains { $0 != 0 }
                })
                let lastInk = try XCTUnwrap((0..<raster.height).reversed().first { row in
                    raster.rasterData[(row * raster.widthBytes)..<((row + 1) * raster.widthBytes)].contains { $0 != 0 }
                })
                let bottomBlank = raster.height - lastInk - 1
                XCTAssertLessThan(firstInk, 48, "\(format) / \(footer): the actual sample raster must start within 6 mm")
                XCTAssertGreaterThanOrEqual(bottomBlank, 28, "\(format) / \(footer): the digital receipt must keep its normal bottom border")
                let envelope = try PrintJobEnvelope.receipt(
                    rasterizedImage: raster, sessionIdentifier: SamplePrintPolicy.auditSessionIdentifier,
                    source: .operatorSample, copyIndex: 1, copyCount: 1,
                    batchID: UUID(), transportPolicy: .safeIntegrity
                )
                XCTAssertEqual(envelope.rasterDataRange.lowerBound, 10, "Only ESC @ and the eight-byte raster header may precede raster rows")
                XCTAssertEqual(envelope.payload.prefix(2), Data([0x1B, 0x40]), "No leading line feed, text, or paper movement")
                let printed = try ThermalImageRasterizer.receiptPrintRaster(for: raster)
                XCTAssertEqual(envelope.payload.subdata(in: 2..<(2 + printed.command.count)), printed.command)
                XCTAssertEqual(envelope.imageHeight, lastInk + 1, "Trim blank rows only in the paper copy")
                XCTAssertEqual(envelope.rasterByteCount, (lastInk + 1) * raster.widthBytes)
                XCTAssertTrue(envelope.payload[envelope.rasterDataRange.lowerBound..<(envelope.rasterDataRange.lowerBound + raster.widthBytes)].contains { $0 != 0 }, "Footer-first paper must begin on an ink row with no programmed bottom gap")
                XCTAssertEqual(envelope.payload.subdata(in: envelope.rasterDataRange.upperBound..<envelope.payload.count), Data([0x1D, 0x56, 0x42, 0x00]), "The cut must follow the header without extra line feeds")
                print("Sample margins: \(format.rawValue), \(footer.rawValue), digital bottom \(bottomBlank) dots, paper bottom 0 dots")
            }
        }
    }

    func testPhotoPassSampleUsesOperatorDetails() {
        var details = SamplePhotoPassDetails()
        details.name = "  Jamie   Cruz  "
        details.note = "Opening night"
        details.includesSignature = false
        let data = details.sessionData(configuration: .default)
        XCTAssertEqual(data.name, "Jamie Cruz")
        XCTAssertEqual(data.notes, "Opening night")
        XCTAssertTrue(data.signature.isEmpty)
        details.includesSignature = true
        XCTAssertFalse(details.sessionData(configuration: .default).signature.isEmpty)
    }

    // MARK: Prepared raster and printing

    func testPrintSendsTheExactPreparedRasterForEveryCopyAndNeverRecomposes() async throws {
        let model = makeModel()
        model.setFormat(.duo)
        model.addImported([photo(0), photo(1)])
        try await waitForPreview(model)
        let prepared = try XCTUnwrap(model.printableSample)
        XCTAssertEqual(model.previewMode, .blackAndWhite)
        XCTAssertTrue(model.previewImage === prepared.monochrome.image)
        model.previewMode = .thermalRaster
        XCTAssertTrue(model.previewImage === prepared.previewImage)
        model.previewMode = .blackAndWhite
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(model.prepared?.previewImage === prepared.previewImage, "Switching modes must retain the prepared images")
        XCTAssertTrue(model.prepared?.monochrome.image === prepared.monochrome.image)
        model.copies = 3

        var sent: [(Data, Int, Int, UUID)] = []
        let finished = expectation(description: "copies")
        model.print(gate: openGate) { raster, copy, copies, batch in
            sent.append((raster.rasterCommand, copy, copies, batch))
            if copy == copies { finished.fulfill() }
            return .success(())
        }
        // A rapid second tap while printing is ignored.
        model.print(gate: openGate) { _, _, _, _ in
            XCTFail("Second tap must not print")
            return .success(())
        }
        await fulfillment(of: [finished], timeout: 10)
        try await waitUntil { !model.isPrinting }

        XCTAssertEqual(sent.map(\.1), [1, 2, 3])
        XCTAssertTrue(sent.allSatisfy { $0.2 == 3 && $0.3 == sent[0].3 })
        XCTAssertTrue(sent.allSatisfy { $0.0 == prepared.raster.rasterCommand })
        XCTAssertEqual(model.status, "3 samples printed.")
    }

    func testFailedCopyStopsTheBatch() async throws {
        let model = makeModel()
        model.setFormat(.solo)
        model.addImported([photo(0)])
        try await waitForPreview(model)
        model.copies = 4
        var attempts = 0
        model.print(gate: openGate) { _, copy, _, _ in
            attempts += 1
            return copy == 2 ? .failure(PrinterNetworkError.jobAlreadyActive) : .success(())
        }
        try await waitUntil { !model.isPrinting }
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(model.status, "1 of 4 printed. Printer needs attention.")
    }

    func testAnyChangeInvalidatesThePreparedRaster() async throws {
        let model = makeModel()
        model.setFormat(.duo)
        let photos = (0..<3).map(photo)
        model.addImported(photos)
        try await waitForPreview(model)
        XCTAssertNotNil(model.printableSample)

        model.assign(photos[2].id, to: 1)
        XCTAssertNil(model.printableSample, "Replacing a photo must discard the approved raster")
        XCTAssertNil(model.previewImage)
        XCTAssertFalse(model.canSavePreview)
        try await waitForPreview(model)
        model.moveSlot(0, by: 1)
        XCTAssertNil(model.printableSample)
        try await waitForPreview(model)
        model.setFormat(.passport)
        XCTAssertNil(model.printableSample)
        try await waitForPreview(model)
        model.photoPass.name = "Someone Else"
        XCTAssertNil(model.printableSample)
        try await waitForPreview(model)
        model.footerStyle = model.footerStyle == .integratedGalleryQR ? .decorativeBarcodeOnly : .integratedGalleryQR
        XCTAssertNil(model.currentPreview)
        try await waitForPreview(model)
        model.branding = .savedEvent
        XCTAssertNil(model.currentPreview)
    }

    func testBothModesSaveNativePNGWithoutPrinterOrEventAndIgnoreDuplicateTap() async throws {
        let model = makeModel()
        model.setFormat(.solo)
        model.addImported([photo(0)])
        try await waitForPreview(model)
        let sample = try XCTUnwrap(model.currentPreview)
        let writer = SamplePhotosWriter()
        for mode in SampleReceiptPreviewMode.allCases {
            model.previewMode = mode
            model.savePreview(writer: writer)
            model.savePreview(writer: writer)
            XCTAssertTrue(model.isSaving)
            XCTAssertFalse(model.canSavePreview)
            // Changing tabs while saving must not change which bytes were selected.
            model.previewMode = mode == .blackAndWhite ? .thermalRaster : .blackAndWhite
            try await waitUntil { !model.isSaving }
            XCTAssertEqual(model.saveStatus, "\(mode.title) saved to Photos.")
        }
        let saved = await writer.saved
        XCTAssertEqual(saved.map(\.data), [sample.monochrome.pngData, sample.raster.previewPNGData])
        XCTAssertTrue(saved[0].url.lastPathComponent.hasPrefix("made-to-keep-sample-bw-"))
        XCTAssertTrue(saved[1].url.lastPathComponent.hasPrefix("made-to-keep-sample-thermal-"))
        XCTAssertTrue(saved.allSatisfy { $0.url.pathExtension == "png" && !FileManager.default.fileExists(atPath: $0.url.path) })
        XCTAssertTrue(model.prepared?.previewImage === sample.previewImage)
    }

    func testSaveDenialAndStorageFailureProvideFeedbackAndAllowRetry() async throws {
        let model = makeModel()
        model.setFormat(.solo)
        model.addImported([photo(0)])
        try await waitForPreview(model)
        for allowed in [false, true] {
            let writer = SamplePhotosWriter(allowed: allowed, fails: true)
            model.savePreview(writer: writer)
            try await waitUntil { !model.isSaving }
            XCTAssertEqual(model.saveStatus, (allowed ? MediaExportError.saveFailed : .permission).localizedDescription)
            XCTAssertTrue(model.canSavePreview)
            let saved = await writer.saved
            XCTAssertTrue(saved.isEmpty)
        }
    }

    func testEditsDuringPhotosPermissionNeverExportTheOldPreview() async throws {
        let model = makeModel()
        model.setFormat(.solo)
        model.addImported([photo(0)])
        try await waitForPreview(model)
        let writer = SamplePhotosWriter(holdsPermission: true)
        model.savePreview(writer: writer)
        while !(await writer.permissionRequested) { try await Task.sleep(for: .milliseconds(10)) }
        model.setFormat(.duo)
        await writer.allowPermission()
        try await waitUntil { !model.isSaving }
        let saved = await writer.saved
        XCTAssertTrue(saved.isEmpty)
        XCTAssertEqual(model.saveStatus, "Receipt changed. Review the current preview and save again.")
        model.savePreview(writer: writer)
        XCTAssertFalse(model.isSaving, "Rendering content cannot be exported")
        try await waitForPreview(model)
        model.beginImport()
        model.savePreview(writer: writer)
        XCTAssertFalse(model.isSaving, "An in-progress import cannot export the previous photos")
    }

    func testIncompleteOrBlockedSamplesCannotPrint() async throws {
        let model = makeModel()
        model.setFormat(.grid)
        model.addImported([photo(0)])
        try await waitForPreview(model)
        XCTAssertNotNil(model.previewImage, "Empty slots still preview with placeholders")
        XCTAssertNil(model.printableSample)
        XCTAssertFalse(model.canPrint(openGate))

        model.addImported((1...3).map(photo))
        try await waitForPreview(model)
        XCTAssertTrue(model.canPrint(openGate))
        var guest = openGate
        guest.guestSessionActive = true
        XCTAssertFalse(model.canPrint(guest))
        XCTAssertEqual(model.blockedReason(guest), "A guest session is in progress. Print samples between guests.")
    }

    func testSavedBrandingIsOnlyOfferedWhenSavedAndNeverUsesDrafts() {
        let standardOnly = makeModel()
        XCTAssertFalse(standardOnly.hasSavedEventBranding)
        XCTAssertEqual(standardOnly.branding, .standard)
        XCTAssertNil(standardOnly.request.eventProfile)

        let saved = profile(enabled: true, name: "MARK & ANNA")
        let branded = SamplePrintStudioModel(loadProfile: { saved }, photoQualityProfile: { .customerPrintDefault })
        XCTAssertTrue(branded.hasSavedEventBranding)
        XCTAssertEqual(branded.branding, .savedEvent)
        XCTAssertEqual(branded.request.eventProfile, saved.normalized())
        branded.branding = .standard
        XCTAssertNil(branded.request.eventProfile)
    }

    // MARK: Import decoding

    func testExplicitPreviewDesignStaysIsolatedFromAppliedBranding() {
        var draft = profile(enabled: true, name: "Preview Only")
        draft.receiptHeader = .coBrandedRecommended
        let snapshot = draft.normalized()
        var appliedLoads = 0
        let model = SamplePrintStudioModel(previewProfile: draft, loadProfile: {
            appliedLoads += 1
            return self.profile(enabled: true, name: "Applied Event")
        }, photoQualityProfile: { .customerPrintDefault })
        XCTAssertEqual(model.request.eventProfile, snapshot)
        draft.eventName = "Later edit"
        model.reloadSavedBranding()
        XCTAssertEqual(model.request.eventProfile, snapshot)
        XCTAssertEqual(appliedLoads, 0)
        model.branding = .standard
        XCTAssertNil(model.request.eventProfile)
    }

    func testDecoderAppliesOrientationAndBoundsLargePhotos() throws {
        let data = try jpeg(width: 4_000, height: 3_000, orientation: .right)
        let decoded = try XCTUnwrap(SamplePhotoDecoder.decode(data))
        XCTAssertEqual(decoded.image.size.width, 1_500, accuracy: 1)
        XCTAssertEqual(decoded.image.size.height, 2_000, accuracy: 1)
        XCTAssertLessThanOrEqual(max(decoded.thumbnail.size.width, decoded.thumbnail.size.height), 320)
        XCTAssertNil(SamplePhotoDecoder.decode(Data("not an image".utf8)))
    }

    // MARK: Helpers

    private var fixedDate: Date { Date(timeIntervalSince1970: 1_788_692_040) }

    private func makeModel() -> SamplePrintStudioModel {
        SamplePrintStudioModel(loadProfile: { [self] in profile(enabled: false, name: "") }, photoQualityProfile: { .customerPrintDefault })
    }

    private func profile(enabled: Bool, name: String) -> EventProfile {
        EventProfile(isEnabled: enabled, eventName: name, subtitle: "", includeEventDate: false, eventDate: fixedDate, shortMessage: "")
    }

    private func photo(_ index: Int) -> SamplePrintPhoto {
        let size = index.isMultiple(of: 2) ? CGSize(width: 1200, height: 800) : CGSize(width: 800, height: 1200)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor(hue: CGFloat(index) / 7, saturation: 0.8, brightness: 0.6, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        return SamplePrintPhoto(id: UUID(), image: image, thumbnail: image)
    }

    private func waitForPreview(_ model: SamplePrintStudioModel) async throws {
        try await waitUntil { model.previewState == .ready && model.prepared?.request == model.request }
    }

    private func waitUntil(timeout: TimeInterval = 60, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("Timed out") }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private func darkPixels(in image: CGImage, rect: CGRect) -> Int {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 255, count: width * height)
        let space = CGColorSpaceCreateDeviceGray()
        pixels.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width, space: space, bitmapInfo: CGImageAlphaInfo.none.rawValue)
            context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        var count = 0
        let minY = max(0, Int(rect.minY)), maxY = min(height, Int(rect.maxY.rounded(.up)))
        for y in minY..<maxY {
            for x in 0..<width where pixels[y * width + x] < 128 { count += 1 }
        }
        return count
    }

    private func jpeg(width: Int, height: Int, orientation: CGImagePropertyOrientation) throws -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
            UIColor.darkGray.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(image.cgImage), [kCGImagePropertyOrientation: orientation.rawValue] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
}

private actor SamplePhotosWriter: PhotosLibraryWriting {
    struct Saved: Sendable { let url: URL; let data: Data }
    let allowed: Bool
    let fails: Bool
    let holdsPermission: Bool
    var permissionRequested = false
    var saved: [Saved] = []
    private var permission: CheckedContinuation<Bool, Never>?

    init(allowed: Bool = true, fails: Bool = false, holdsPermission: Bool = false) {
        self.allowed = allowed
        self.fails = fails
        self.holdsPermission = holdsPermission
    }
    func requestAddAccess() async -> Bool {
        permissionRequested = true
        if holdsPermission { return await withCheckedContinuation { permission = $0 } }
        return allowed
    }
    func allowPermission() { permission?.resume(returning: true); permission = nil }
    func save(files: [URL]) async throws {
        if fails { throw CocoaError(.fileWriteOutOfSpace) }
        saved += try files.map { Saved(url: $0, data: try Data(contentsOf: $0)) }
    }
}
