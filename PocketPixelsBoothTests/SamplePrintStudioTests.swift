import ImageIO
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import PocketPixelsBooth

@MainActor
final class SamplePrintStudioTests: XCTestCase {
    private let openGate = SamplePrintStudioModel.PrinterGate(printerBusy: false, recoveryLocked: false, unresolvedPrint: false, guestSessionActive: false)

    // MARK: Policy

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

            let guest = try ReceiptComposer.compose(
                photos: photos, sessionIdentifier: "PP-20260907-161400", date: fixedDate, galleryURL: nil, format: format,
                passport: format == .passport ? SamplePhotoPassDetails().sessionData(configuration: .default) : nil
            )
            XCTAssertEqual(sample.receipt.height, guest.height, "\(format.rawValue): sample must be exactly as long as a guest receipt")

            // Where a guest receipt prints its session identifier, the sample prints nothing.
            let plan = try ReceiptComposer.makeLayoutPlan(format: format, includesGalleryQRCode: false, passport: format == .passport ? SamplePhotoPassDetails().sessionData(configuration: .default) : nil, date: fixedDate)
            let identifierBand = CGRect(x: 0, y: plan.sessionIdentifierFrame.minY, width: CGFloat(plan.width), height: plan.sessionIdentifierFrame.height)
            let sampleImage = try XCTUnwrap(UIImage(data: sample.receipt.imagePNGData)?.cgImage)
            let guestImage = try XCTUnwrap(UIImage(data: guest.imagePNGData)?.cgImage)
            XCTAssertEqual(darkPixels(in: sampleImage, rect: identifierBand), 0, "\(format.rawValue): sample prints a session identifier")
            XCTAssertGreaterThan(darkPixels(in: guestImage, rect: identifierBand), 0, "\(format.rawValue): guest identifier band was not measured")
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
        try await waitForPreview(model)
        model.moveSlot(0, by: 1)
        XCTAssertNil(model.printableSample)
        try await waitForPreview(model)
        model.setFormat(.passport)
        XCTAssertNil(model.printableSample)
        try await waitForPreview(model)
        model.photoPass.name = "Someone Else"
        XCTAssertNil(model.printableSample)
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
