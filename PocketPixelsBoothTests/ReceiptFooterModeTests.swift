import CoreImage
import UIKit
import XCTest
@testable import PocketPixelsBooth

final class ReceiptFooterModeTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_791_889_200)
    private let url = URL(string: "https://pocket-pixels-gallery.pocketpixels-ceb.workers.dev/?g=\(String(repeating: "a", count: 64))")!
    private var artifacts: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("BuildArtifacts/GalleryFooter", isDirectory: true)
    }

    func testMigrationAndUnknownValues() throws {
        let suite = "FooterMigration.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(ReceiptPrintSettingsStore.load(defaults: defaults).footerStyle, .integratedGalleryQR)
        defaults.set(false, forKey: ReceiptPrintSettingsStore.printsGalleryQRKey)
        XCTAssertEqual(ReceiptPrintSettingsStore.load(defaults: defaults).footerStyle, .decorativeBarcodeOnly)
        defaults.set(true, forKey: ReceiptPrintSettingsStore.printsGalleryQRKey)
        XCTAssertEqual(ReceiptPrintSettingsStore.load(defaults: defaults).footerStyle, .integratedGalleryQR)
        for style in ReceiptFooterStyle.allCases {
            let value = ReceiptPrintOptions(footerStyle: style)
            ReceiptPrintSettingsStore.save(value, defaults: defaults)
            XCTAssertEqual(ReceiptPrintSettingsStore.load(defaults: defaults), value)
            XCTAssertEqual(try JSONDecoder().decode(ReceiptPrintOptions.self, from: JSONEncoder().encode(value)), value)
        }
        // Frozen legacy payloads keep their historical geometry; device preference ON migrates.
        for (json, style) in [("{\"includesPrintedGalleryQR\":true}", ReceiptFooterStyle.classicBarcodeAndGalleryQR),
                              ("{\"includesPrintedGalleryQR\":false}", .decorativeBarcodeOnly),
                              ("{\"footerStyle\":\"future\"}", .integratedGalleryQR)] {
            XCTAssertEqual(try JSONDecoder().decode(ReceiptPrintOptions.self, from: Data(json.utf8)).footerStyle, style)
        }
        let oldEvent = try JSONDecoder().decode(EventReceiptDesignConfiguration.self, from: Data("{}".utf8))
        XCTAssertNil(oldEvent.footerStyleOverride)
    }

    func testEventOverrideWithoutLogoAndInheritance() throws {
        var event = SavedEventDesign.new(name: "Footer Only", venue: "Cebu")
        XCTAssertFalse(event.personalizeReceipt)
        XCTAssertNil(event.profile.receiptDesign.footerStyleOverride)
        event.profile.receiptDesign.footerStyleOverride = .decorativeBarcodeOnly
        let restored = try JSONDecoder().decode(SavedEventDesign.self, from: JSONEncoder().encode(event))
        XCTAssertNil(restored.appliedProfile().activeReceiptSnapshot)
        XCTAssertEqual(ReceiptPrintOptions.default.resolved(for: restored.appliedProfile()).footerStyle, .decorativeBarcodeOnly)
        event.profile.receiptDesign.footerStyleOverride = nil
        let classic = ReceiptPrintOptions(footerStyle: .classicBarcodeAndGalleryQR)
        XCTAssertEqual(classic.resolved(for: event.appliedProfile()), classic)
    }

    func testAllModesFormatsAndFinalThermalQRWithVisualArtifacts() throws {
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
        let detector = try XCTUnwrap(CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
        let artworkFormat = UIGraphicsImageRendererFormat()
        artworkFormat.scale = 1
        let artwork = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 160), format: artworkFormat).image { _ in
            UIColor.white.setFill(); UIBezierPath(rect: CGRect(x: 0, y: 0, width: 400, height: 160)).fill()
            NSString(string: "EVENT").draw(at: CGPoint(x: 70, y: 45), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 50), .foregroundColor: UIColor.black])
        }
        let assetStore = try EventHeaderAssetStore()
        let asset = try assetStore.importImageData(XCTUnwrap(artwork.pngData()))
        var event = EventProfile.pocketPixelsDefault
        event.isEnabled = true
        event.showEventTextBlock = false
        event.receiptHeader.mode = .customEventHeader
        event.receiptHeader.brandingMode = .coBranded
        event.receiptHeader.assetIdentifier = asset
        var rasterManifest: [[String: Any]] = []
        for format in BoothFormat.allCases {
            let photos = (0..<format.photoCount).map { ReliabilityFixtures.syntheticPhoto(session: 101, photo: $0, format: format) }
            for style in ReceiptFooterStyle.allCases {
                for logo in [false, true] {
                    let receipt = try ReceiptComposer.compose(photos: photos, sessionIdentifier: "PP-20261016-161320", date: date,
                        galleryURL: url, format: format, eventProfile: logo ? event : nil,
                        passport: format == .passport ? .photoPassDebugFixture : nil, printOptions: ReceiptPrintOptions(footerStyle: style))
                    let image = try XCTUnwrap(UIImage(data: receipt.imagePNGData))
                    let raster = try ThermalImageRasterizer.rasterize(image, purpose: .completeReceipt)
                    let thermal = try XCTUnwrap(UIImage(data: raster.previewPNGData)?.cgImage)
                    let codes = detector.features(in: CIImage(cgImage: thermal)).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
                    XCTAssertEqual(codes, style == .decorativeBarcodeOnly ? [] : [url.absoluteString], "\(format) \(style) logo=\(logo)")
                    XCTAssertEqual(receipt.includesPrintedGalleryQR, style != .decorativeBarcodeOnly)
                    XCTAssertEqual(raster.width, 576)
                    XCTAssertEqual(raster.height, receipt.height)
                    let name = "\(format.rawValue)_\(style.rawValue)_logo_\(logo)"
                    try receipt.imagePNGData.write(to: artifacts.appendingPathComponent("\(name).png"))
                    try raster.previewPNGData.write(to: artifacts.appendingPathComponent("\(name)_1bit.png"))
                    try raster.rasterData.write(to: artifacts.appendingPathComponent("\(name).raster.bin"))
                    rasterManifest.append(["name": name, "width": raster.width, "height": raster.height,
                        "widthBytes": raster.widthBytes, "format": format.rawValue, "footerStyle": style.rawValue,
                        "eventLogo": logo, "includesPrintedGalleryQR": receipt.includesPrintedGalleryQR,
                        "rasterFile": "\(name).raster.bin", "previewFile": "\(name)_1bit.png"])

                    if format == .strip && !logo {
                        let attachment = XCTAttachment(data: raster.previewPNGData, uniformTypeIdentifier: "public.png")
                        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
                    }
                }
            }
        }
        try JSONSerialization.data(withJSONObject: rasterManifest, options: [.prettyPrinted, .sortedKeys])
            .write(to: artifacts.appendingPathComponent("raster-manifest.json"))
        // Legacy Passport uses the same footer, with its original cards preserved.
        for style in ReceiptFooterStyle.allCases {
            XCTAssertNoThrow(try ReceiptComposer.compose(photos: (0..<BoothFormat.passport.photoCount).map {
                ReliabilityFixtures.syntheticPhoto(session: 102, photo: $0, format: .passport)
            }, sessionIdentifier: "PP-LEGACY", galleryURL: url, format: .passport, passport: .debugFixture, printOptions: ReceiptPrintOptions(footerStyle: style)))
        }
    }

    func testModuleGeometryQuietZonesAndProtectedArea() throws {
        let size = max(ReceiptComposer.receiptQRCodeSize, try GalleryQRCodeGenerator.moduleAlignedPixelSize(for: url, moduleScale: 4))
        let metrics = try GalleryQRCodeGenerator.makeRenderMetrics(for: url, pixelSize: size)
        XCTAssertGreaterThanOrEqual(metrics.moduleScale, 4)
        XCTAssertEqual(metrics.quietZoneModules, 4)
        XCTAssertEqual(metrics.matrixModules % 4, 1, "Metrics exclude Core Image’s native white border")
        XCTAssertLessThanOrEqual(metrics.renderedTotalPixelSize, size)
        let plan = try ReceiptComposer.makeLayoutPlan(format: .strip, footerStyle: .integratedGalleryQR, qrDots: size)
        let qr = try XCTUnwrap(plan.qrRect)
        XCTAssertEqual(qr, plan.footer.integratedQRFrame)
        XCTAssertTrue(plan.footer.barcodeBars.isEmpty)
        XCTAssertLessThan(qr.maxY, plan.sessionIdentifierFrame.minY)
        XCTAssertTrue(ReceiptComposer.stickerProtectedRects(for: plan).contains { $0.contains(qr) })
        let classic = try ReceiptComposer.makeLayoutPlan(format: .strip, footerStyle: .classicBarcodeAndGalleryQR)
        XCTAssertFalse(classic.footer.barcodeBars.isEmpty)
        XCTAssertGreaterThan(try XCTUnwrap(classic.qrRect).minY, CGFloat(classic.footer.bottom))
        let longURL = URL(string: "https://example.com/\(String(repeating: "path", count: 160))?g=\(String(repeating: "b", count: 64))")!
        XCTAssertThrowsError(try ReceiptComposer.compose(photos: [ReliabilityFixtures.syntheticPhoto(session: 103, photo: 0, format: .solo)], sessionIdentifier: "PP-TOO-LONG", galleryURL: longURL, format: .solo))
        XCTAssertThrowsError(try GalleryQRCodeGenerator.makeQRCodeImage(for: url, pixelSize: 20))
        let receipt = try ReceiptComposer.compose(photos: [ReliabilityFixtures.syntheticPhoto(session: 105, photo: 0, format: .solo)], sessionIdentifier: "PP-MODULES", galleryURL: url, format: .solo)
        let raster = try ThermalImageRasterizer.rasterize(XCTUnwrap(UIImage(data: receipt.imagePNGData)), purpose: .completeReceipt)
        let soloPlan = try ReceiptComposer.makeLayoutPlan(format: .solo, footerStyle: .integratedGalleryQR, qrDots: size)
        let soloQR = try XCTUnwrap(soloPlan.qrRect)
        let expected = try XCTUnwrap(GalleryQRCodeGenerator.makeQRCodeImage(for: url, pixelSize: size).cgImage)
        var pixels = [UInt8](repeating: 0, count: size * size)
        let context = try XCTUnwrap(CGContext(data: &pixels, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        context.draw(expected, in: CGRect(x: 0, y: 0, width: size, height: size))
        let bits = [UInt8](raster.rasterData)
        var mismatches = 0
        for y in 0..<size {
            for x in 0..<size {
                let dotX = Int(soloQR.minX) + x, dotY = Int(soloQR.minY) + y
                let ink = bits[dotY * raster.widthBytes + dotX / 8] & (0x80 >> UInt8(dotX % 8)) != 0
                if ink != (pixels[y * size + x] < 128) { mismatches += 1 }
                if x < 16 || y < 16 || x >= size - 16 || y >= size - 16 {
                    XCTAssertFalse(ink, "QR quiet zone must remain white")
                }
            }
        }
        XCTAssertEqual(mismatches, 0, "Final printer bits preserve every QR pixel without dither or resampling")
        print("FOOTER_QR_METRICS matrix=\(metrics.matrixModules) quiet=\(metrics.quietZoneModules) scale=\(metrics.moduleScale) allocation=\(size) total=\(metrics.renderedTotalPixelSize)")
    }

    func testLargestSupportedIntegratedURLExpandsAtIntegerScaleAndScans() throws {
        let candidates = try stride(from: 0, through: 220, by: 10).map { length -> (URL, Int) in
            let candidate = URL(string: "https://gallery.example.com/\(String(repeating: "x", count: length))?g=\(String(repeating: "f", count: 64))")!
            return (candidate, max(ReceiptComposer.receiptQRCodeSize, try GalleryQRCodeGenerator.moduleAlignedPixelSize(for: candidate, moduleScale: 4)))
        }
        let (candidate, size) = try XCTUnwrap(candidates.last { $0.1 <= 288 })
        XCTAssertGreaterThan(size, ReceiptComposer.receiptQRCodeSize)
        let receipt = try ReceiptComposer.compose(photos: [ReliabilityFixtures.syntheticPhoto(session: 107, photo: 0, format: .solo)], sessionIdentifier: "PP-LONG-SUPPORTED", galleryURL: candidate, format: .solo)
        let raster = try ThermalImageRasterizer.rasterize(XCTUnwrap(UIImage(data: receipt.imagePNGData)), purpose: .completeReceipt)
        let detector = try XCTUnwrap(CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
        let messages = detector.features(in: CIImage(cgImage: try XCTUnwrap(UIImage(data: raster.previewPNGData)?.cgImage))).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
        XCTAssertEqual(messages, [candidate.absoluteString])
        let metrics = try GalleryQRCodeGenerator.makeRenderMetrics(for: candidate, pixelSize: size)
        XCTAssertEqual(metrics.moduleScale, 4)
        print("LARGEST_SUPPORTED_QR urlBytes=\(candidate.absoluteString.utf8.count) matrix=\(metrics.matrixModules) allocation=\(size)")
    }

    @MainActor
    func testAdmissionFreezesFooterBeforeFormatSelectionAndRecoveryPersistsIt() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FooterAdmission-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        final class Source { var options = ReceiptPrintOptions(footerStyle: .classicBarcodeAndGalleryQR) }
        let source = Source()
        var environment = BoothSessionEnvironment.customer
        environment.archiveDirectory = directory.appendingPathComponent("archive")
        environment.recoveryDirectory = directory.appendingPathComponent("recovery")
        environment.recordsCustomerSessionMetrics = false
        environment.deliversGallery = false
        environment.receiptPrintOptionsSource = { source.options }
        environment.eventProfileSource = { .pocketPixelsDefault }
        let model = BoothSessionViewModel(environment: environment, captureConfirmationPause: {})
        model.state = .welcome
        model.startSession()
        guard model.state == .choosingFormat else { throw XCTSkip("Admission blocked by simulator configuration: \(model.state)") }
        XCTAssertEqual(model.sessionPrintOptions.footerStyle, .classicBarcodeAndGalleryQR)
        source.options.footerStyle = .decorativeBarcodeOnly
        model.selectBoothFormat(.solo)
        XCTAssertEqual(model.sessionPrintOptions.footerStyle, .classicBarcodeAndGalleryQR)
        let recovery = try AppRecoveryStore(directoryURL: environment.recoveryDirectory)
        let snapshot = try XCTUnwrap(recovery.load())
        XCTAssertEqual(snapshot.receiptPrintOptions?.footerStyle, .classicBarcodeAndGalleryQR)
    }

    @MainActor
    func testCheckoutCheckpointRoundTripAndOlderPayload() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FooterCheckout-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try CheckoutCheckpointStore(directory: directory)
        let checkpoint = CheckoutCheckpoint(id: "footer-checkout", environment: "test", eventID: "event", policyRevisionID: "policy",
            unitPriceCentavos: 100, copies: 2, format: BoothFormat.solo.rawValue, phase: .claimed, createdAt: date, updatedAt: date,
            receiptPrintOptions: ReceiptPrintOptions(footerStyle: .decorativeBarcodeOnly))
        try store.begin(checkpoint)
        XCTAssertEqual(try CheckoutCheckpointStore(directory: directory).checkpoint(id: checkpoint.id)?.receiptPrintOptions, checkpoint.receiptPrintOptions)
        let encoded = try JSONEncoder().encode(checkpoint)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "receiptPrintOptions")
        XCTAssertNil(try JSONDecoder().decode(CheckoutCheckpoint.self, from: JSONSerialization.data(withJSONObject: legacy)).receiptPrintOptions)
    }

    func testArchiveKeepsFrozenOptionsAndOlderArchivesReprintOriginalRaster() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FooterArchive-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let photos = [ReliabilityFixtures.syntheticPhoto(session: 106, photo: 0, format: .solo)]
        let options = ReceiptPrintOptions(footerStyle: .decorativeBarcodeOnly)
        let token = String(repeating: "a", count: 64)
        let receipt = try ReceiptComposer.compose(photos: photos, sessionIdentifier: "PP-ARCHIVE-FOOTER", date: date, galleryURL: url, format: .solo, printOptions: options)
        let raster = try ThermalImageRasterizer.rasterize(XCTUnwrap(UIImage(data: receipt.imagePNGData)), purpose: .completeReceipt)
        let session = CommittedGallerySession(sessionIdentifier: receipt.sessionIdentifier, createdAt: date, galleryToken: token,
            galleryURL: url, photos: photos, format: .solo, eventProfile: nil, printOptions: options)
        let store = try RecentSessionArchiveStore(directoryURL: directory)
        try store.save(RecentSessionArchivePayload(committedSession: session, composedReceipt: receipt, receiptPreviewPNGData: receipt.imagePNGData,
            thermalPreviewPNGData: raster.previewPNGData, rasterizedImage: raster, photoThumbnailData: []))
        XCTAssertEqual(try store.load(archiveID: token).receiptPrintOptions, options)
        let metadataURL = directory.appendingPathComponent(token).appendingPathComponent("metadata.json")
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: metadataURL)) as? [String: Any])
        legacy.removeValue(forKey: "receiptPrintOptions")
        try JSONSerialization.data(withJSONObject: legacy).write(to: metadataURL)
        let reopened = try RecentSessionArchiveStore(directoryURL: directory).load(archiveID: token)
        XCTAssertNil(reopened.receiptPrintOptions)
        XCTAssertEqual(reopened.rasterizedImage.rasterCommand, raster.rasterCommand)
        XCTAssertEqual(reopened.receiptPreviewPNGData, receipt.imagePNGData)
    }

    func testSamplesHaveNoScannableGalleryButPreserveSelectedGeometry() throws {
        let photos = [ReliabilityFixtures.syntheticPhoto(session: 104, photo: 0, format: .solo)]
        for style in ReceiptFooterStyle.allCases {
            let sample = try SamplePrintComposer.compose(photos: photos, format: .solo, eventProfile: nil, photoPass: nil, date: date, photoQualityProfile: .customerPrintDefault, printOptions: ReceiptPrintOptions(footerStyle: style))
            XCTAssertFalse(sample.includesPrintedGalleryQR)
            let raster = try ThermalImageRasterizer.rasterize(XCTUnwrap(UIImage(data: sample.imagePNGData)), purpose: .completeReceipt)
            let detector = try XCTUnwrap(CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: nil))
            XCTAssertTrue(detector.features(in: CIImage(cgImage: try XCTUnwrap(UIImage(data: raster.previewPNGData)?.cgImage))).isEmpty)
            let plan = try ReceiptComposer.makeLayoutPlan(format: .solo, footerStyle: style)
            XCTAssertEqual(sample.height, plan.height)
        }
    }
}
