import XCTest
import UIKit
import CoreImage
@testable import PocketPixelsBooth

@MainActor
final class GalleryReceiptStyleTests: XCTestCase {
    func testIndependentDeviceStoreAndLogoOffEventInheritance() throws {
        let suite = "GalleryStyles.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(GalleryReceiptSettingsStore.load(defaults: defaults), .shareFriendly)
        let physical = ReceiptPrintOptions(footerStyle: .classicBarcodeAndGalleryQR)
        ReceiptPrintSettingsStore.save(physical, defaults: defaults)
        var event = SavedEventDesign.new(name: "No Logo", venue: "Cebu")
        for style in GalleryReceiptStyle.allCases {
            GalleryReceiptSettingsStore.save(style, defaults: defaults)
            XCTAssertEqual(GalleryReceiptSettingsStore.load(defaults: defaults), style)
            XCTAssertEqual(ReceiptPrintSettingsStore.load(defaults: defaults), physical)
            XCTAssertEqual(GalleryReceiptStyle.resolve(device: style, profile: event.appliedProfile()), style)
            event.profile.galleryReceiptStyleOverride = style
            let restored = try JSONDecoder().decode(SavedEventDesign.self, from: JSONEncoder().encode(event))
            XCTAssertNil(restored.appliedProfile().activeReceiptSnapshot)
            XCTAssertEqual(GalleryReceiptStyle.resolve(device: .shareFriendly, profile: restored.appliedProfile()), style)
            event.profile.galleryReceiptStyleOverride = nil
        }
        XCTAssertEqual(GalleryReceiptStyle.resolve(device: .shareFriendly, profile: .pocketPixelsDefault), .shareFriendly)
    }

    func testEveryFooterAndDefaultUsesAuthenticPublicCompositionAndDurableQueue() throws {
        let token = String(repeating: "c", count: 64)
        let date = Date(timeIntervalSince1970: 1_791_889_200)
        let base = URL(string: "https://gallery.example.test/")!
        let url = try GalleryURLBuilder.makeGalleryURL(customerGalleryBaseURL: base, galleryToken: token)
        let detector = try XCTUnwrap(CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
        for format in BoothFormat.allCases {
            let photos = (0..<format.photoCount).map { ReliabilityFixtures.syntheticPhoto(session: 111, photo: $0, format: format) }
            for footer in ReceiptFooterStyle.allCases {
                for style in GalleryReceiptStyle.allCases {
                    let options = ReceiptPrintOptions(footerStyle: footer)
                    let passport: PassportSessionData? = format == .passport ? .photoPassDebugFixture : nil
                    let session = CommittedGallerySession(sessionIdentifier: "PP-20261018-120000", createdAt: date,
                        galleryToken: token, galleryURL: url, photos: photos, format: format, eventProfile: nil,
                        passport: passport, printOptions: options, galleryReceiptStyle: style)
                    let physical = try ReceiptComposer.compose(photos: photos, sessionIdentifier: session.sessionIdentifier,
                        date: date, galleryURL: url, format: format, passport: passport, printOptions: options)
                    let physicalImage = try XCTUnwrap(UIImage(data: physical.imagePNGData))
                    let before = try ThermalImageRasterizer.rasterize(physicalImage, purpose: .completeReceipt)
                    let original = try BoothSessionViewModel.galleryReceiptImage(for: session, printedReceiptImage: physicalImage, photoQualityProfile: .customerPrintDefault)
                    let alternative = try BoothSessionViewModel.shareFriendlyGalleryReceiptImage(for: session, photoQualityProfile: .customerPrintDefault)
                    XCTAssertEqual(alternative != nil, footer != .decorativeBarcodeOnly)
                    if let alternative {
                        let safe = try ReceiptComposer.compose(photos: photos, sessionIdentifier: session.sessionIdentifier,
                            date: date, galleryURL: url, format: format, passport: passport?.redactedForGallery(),
                            printOptions: ReceiptPrintOptions(footerStyle: .decorativeBarcodeOnly))
                        XCTAssertEqual(alternative.pngData(), UIImage(data: safe.imagePNGData)?.pngData(), "Uses exact safe composer input")
                        XCTAssertTrue(detector.features(in: CIImage(cgImage: try XCTUnwrap(alternative.cgImage))).isEmpty)
                    }
                    let payload = try GoogleDriveGalleryUploadService.preparePayload(photos: photos, composedReceipt: original,
                        sessionID: session.sessionIdentifier, createdAt: date, galleryToken: token, customerGalleryBaseURL: base,
                        shareFriendlyReceipt: alternative, receiptVariants: GalleryReceiptVariants(originalFooterStyle: footer, defaultStyle: style))
                    XCTAssertEqual(payload.schemaVersion, 3)
                    XCTAssertTrue(MonochromeReceiptRenderer.isSmoothMonochromePNG(try XCTUnwrap(payload.thermalReceipt).data))
                    let request = try GoogleDriveGalleryUploadService.makeRequestBody(payload: payload, deviceToken: String(repeating: "test", count: 8))
                    XCTAssertEqual(request.receiptVariants?.defaultStyle, style)
                    XCTAssertEqual(request.shareColorReceipt != nil, alternative != nil)
                    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                    defer { try? FileManager.default.removeItem(at: directory) }
                    let store = try GalleryPendingUploadStore(directoryURL: directory)
                    try store.save(payload)
                    try store.recordAttempt(galleryToken: token)
                    try store.updateDeliveryState(.deliveryUnknown, galleryToken: token)
                    let recovered = try XCTUnwrap(store.load(galleryToken: token))
                    XCTAssertEqual(recovered.receiptVariants, payload.receiptVariants)
                    XCTAssertEqual(recovered.shareColorReceipt?.data, payload.shareColorReceipt?.data)
                    XCTAssertEqual(recovered.photos.map(\.data), payload.photos.map(\.data))
                    XCTAssertEqual(try ThermalImageRasterizer.rasterize(physicalImage, purpose: .completeReceipt).rasterCommand, before.rasterCommand)
                    XCTAssertLessThanOrEqual(payload.metrics.totalDecodedBytes, GalleryPreparedUploadBudget.maximumPreparedDecodedBytes)
                    print("[GalleryStyles] \(format.rawValue)/\(footer.rawValue)/\(style.rawValue) decoded=\(payload.metrics.totalDecodedBytes) json=\(try JSONEncoder().encode(request).count) prepareMs=\(Int((payload.metrics.timing?.imagePreparationDuration ?? 0) * 1000))")
                }
            }
        }
    }

    func testExportSyntheticReleasePayload() throws {
        let token = try GalleryTokenGenerator.makeGalleryToken()
        let base = URL(string: "https://gallery.madetokeepstudios.workers.dev/")!
        let url = try GalleryURLBuilder.makeGalleryURL(customerGalleryBaseURL: base, galleryToken: token)
        let date = Date()
        let id = "\(ReceiptComposer.makeSessionIdentifier(date: date))-\(UUID().uuidString.lowercased())"
        let photos = [ReliabilityFixtures.syntheticPhoto(session: 9191, photo: 0, format: .solo)]
        let session = CommittedGallerySession(sessionIdentifier: id, createdAt: date, galleryToken: token,
            galleryURL: url, photos: photos, format: .solo, eventProfile: nil)
        let composed = try ReceiptComposer.compose(photos: photos, sessionIdentifier: id, date: date, galleryURL: url, format: .solo)
        let payload = try GoogleDriveGalleryUploadService.preparePayload(photos: photos,
            composedReceipt: try XCTUnwrap(UIImage(data: composed.imagePNGData)), sessionID: id,
            createdAt: date, galleryToken: token, customerGalleryBaseURL: base,
            shareFriendlyReceipt: try BoothSessionViewModel.shareFriendlyGalleryReceiptImage(for: session, photoQualityProfile: .customerPrintDefault),
            receiptVariants: GalleryReceiptVariants(originalFooterStyle: .integratedGalleryQR, defaultStyle: .shareFriendly))
        let request = try GoogleDriveGalleryUploadService.makeRequestBody(payload: payload, deviceToken: "synthetic-server-side-credential-placeholder")
        let output = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("DerivedData/gallery-release-synthetic.json")
        try JSONEncoder().encode(request).write(to: output, options: .atomic)
        XCTAssertEqual(payload.schemaVersion, 3)
        XCTAssertGreaterThan(id.count, 32, "Production UUID session identifiers must survive preparation")
    }

    func testRecoveryOptionalFieldKeepsOldRecordsReadableAndNewStyleFrozen() throws {
        let snapshot = AppRecoverySnapshot(schemaVersion: 1, sessionIdentifier: "PP-20261018-120000", createdAt: Date(),
            format: .strip, eventProfile: nil, galleryToken: nil, galleryURL: nil, photoJPEGData: [],
            receiptPreviewPNGData: nil, thermalPreviewPNGData: nil, rasterFingerprint: nil,
            stage: .formatSelected, updatedAt: Date(), galleryReceiptStyle: .asPrinted)
        let data = try JSONEncoder().encode(snapshot)
        XCTAssertEqual(try JSONDecoder().decode(AppRecoverySnapshot.self, from: data).galleryReceiptStyle, .asPrinted)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "galleryReceiptStyle")
        XCTAssertNil(try JSONDecoder().decode(AppRecoverySnapshot.self, from: JSONSerialization.data(withJSONObject: legacy)).galleryReceiptStyle)
    }
}
