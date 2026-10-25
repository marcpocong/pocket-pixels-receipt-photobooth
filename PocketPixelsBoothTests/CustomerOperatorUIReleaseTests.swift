import CoreImage
import SwiftUI
import UIKit
import XCTest
@testable import PocketPixelsBooth

/// Customer receipt preview, camera chrome, Recent Sessions (with the original archived QR) and
/// the operator zoomable receipt viewer. Synthetic photos only; nothing prints or uploads.
@MainActor
final class CustomerOperatorUIReleaseTests: XCTestCase {
    static let portrait = CGSize(width: 834, height: 1194)
    static let landscape = CGSize(width: 1194, height: 834)
    private let legacyBase = "https://pocket-pixels-gallery.pocketpixels-ceb.workers.dev/"
    private let madeToKeepBase = "https://gallery.madetokeep.test/"
    private var root: URL!

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private var scene: UIWindowScene {
        get throws { try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first) }
    }

    // MARK: Customer receipt preview

    private func receiptModel(format: BoothFormat, state: BoothSessionState = .receiptPreview, monochrome: Bool = true) throws -> BoothSessionViewModel {
        let receipt = try StickerFixtures.compose(format)
        let image = try XCTUnwrap(UIImage(data: receipt.imagePNGData))
        let model = BoothSessionViewModel()
        model.selectedBoothFormat = format
        model.receiptImage = image
        model.monochromeReceiptPreview = monochrome ? try MonochromeReceiptRenderer.render(image).image : nil
        model.state = state
        return model
    }

    func testReceiptScreenShowsOneBlackAndWhitePreviewForEveryFormatAndOrientation() async throws {
        for format in BoothFormat.allCases {
            for size in [Self.portrait, Self.landscape] {
                let model = try receiptModel(format: format)
                let image = try await ScreenshotHarness.render(BoothSessionView(viewModel: model), size: size, scene: scene, settle: .milliseconds(900))
                let stats = ScreenStats(image)
                XCTAssertGreaterThan(stats.burgundyFraction, 0.004, "\(format.rawValue) \(size): filled print action and heading are visible")
                // The guest preview is monochrome: the composed (colorless synthetic) receipt has no
                // saturated pixels, and the screen around it is the ivory/burgundy brand palette.
                let name = "receipt-\(format.rawValue)-\(size.width < size.height ? "portrait" : "landscape")"
                add(ScreenshotHarness.attachment(image, name: name))
                try EmojiStickerTests.dump(image.pngData(), name: name + ".png")
            }
        }
    }

    func testReceiptScreenHasNoKeepsakeOrBlackAndWhiteSwitch() throws {
        // The toggle and its state are gone from the guest screen; only one preview resolves.
        let source = try String(contentsOf: Self.sourceURL("BoothSessionView.swift"), encoding: .utf8)
        XCTAssertFalse(source.contains("receiptPreviewModePicker"))
        XCTAssertFalse(source.contains("ReceiptPreviewMode"))
        XCTAssertFalse(source.contains("\"Keepsake\""))
        let model = try receiptModel(format: .grid)
        let preview = GuestReceiptPreview.resolve(receipt: model.receiptImage, monochrome: model.monochromeReceiptPreview)
        XCTAssertTrue(preview.image === model.monochromeReceiptPreview)
    }

    func testPrintingAndPreparingStatesStayMonochrome() async throws {
        for (state, monochrome, name) in [(BoothSessionState.printing, true, "receipt-printing"), (.receiptPreview, false, "receipt-grayscale-fallback")] {
            let model = try receiptModel(format: .strip, state: state, monochrome: monochrome)
            model.galleryQRCodeImage = try GalleryQRCodeGenerator.makeQRCodeImage(for: XCTUnwrap(URL(string: madeToKeepBase + "?g=" + String(repeating: "a", count: 64))))
            let image = try await ScreenshotHarness.render(BoothSessionView(viewModel: model), size: Self.portrait, scene: scene, settle: .milliseconds(900))
            add(ScreenshotHarness.attachment(image, name: name))
            try EmojiStickerTests.dump(image.pngData(), name: name + ".png")
        }
        let preparing = BoothSessionViewModel()
        preparing.selectedBoothFormat = .grid
        preparing.state = .receiptPreview
        let image = try await ScreenshotHarness.render(BoothSessionView(viewModel: preparing), size: Self.landscape, scene: scene, settle: .milliseconds(900))
        add(ScreenshotHarness.attachment(image, name: "receipt-preparing"))
        try EmojiStickerTests.dump(image.pngData(), name: "receipt-preparing.png")
    }

    func testCopyControlsFollowExistingEntitlementRules() throws {
        let model = try receiptModel(format: .solo)
        // No prepaid entitlement: copies cannot be changed by the guest.
        XCTAssertFalse(model.canIncreasePrintCopies)
        XCTAssertFalse(model.canDecreasePrintCopies)
        XCTAssertEqual(model.printButtonTitle, "Print Receipt")
        model.selectedPrintCopies = 3
        XCTAssertEqual(model.printButtonTitle, "Print 3 Copies")
    }

    // MARK: Camera

    func testCameraScreenCompositionInPortraitAndLandscape() async throws {
        for format in [BoothFormat.solo, .duo, .gridSix] {
            for size in [Self.portrait, Self.landscape] {
                let model = BoothSessionViewModel()
                model.selectedBoothFormat = format
                model.isCameraUnavailable = false
                model.state = .cameraReady
                let image = try await ScreenshotHarness.render(BoothSessionView(viewModel: model), size: size, scene: scene, settle: .milliseconds(900))
                // START PHOTOS stays disabled here: the simulator has no running capture session.
                XCTAssertGreaterThan(ScreenStats(image).burgundyFraction, 0.0015)
                let name = "camera-\(format.rawValue)-\(size.width < size.height ? "portrait" : "landscape")"
                add(ScreenshotHarness.attachment(image, name: name))
                try EmojiStickerTests.dump(image.pngData(), name: name + ".png")
            }
        }
        // The taller filled action still leaves a usable aperture on the booth mount.
        for available in CapturePresentationTests.supportedCameraCompositionAreas {
            let layout = CameraScreenLayout(available: available, maximumContentWidth: min(available.width - 48, 620), aspectRatio: 3.0 / 4.0)
            XCTAssertLessThanOrEqual(layout.compositionHeight, available.height)
            XCTAssertGreaterThanOrEqual(min(layout.viewportSize.width, layout.viewportSize.height), 300)
        }
    }

    // MARK: Recent Sessions

    private func saveArchive(store: RecentSessionArchiveStore, token: String, base: String, id: String, format: BoothFormat = .duo, createdAt: Date = Date()) throws -> (URL, ThermalRasterizedImage) {
        let url = try GalleryURLBuilder.makeGalleryURL(customerGalleryBaseURL: XCTUnwrap(URL(string: base)), galleryToken: token)
        let photos = StickerFixtures.photos(for: format)
        let committed = CommittedGallerySession(sessionIdentifier: id, createdAt: createdAt, galleryToken: token, galleryURL: url, photos: photos, format: format, eventProfile: nil)
        let receipt = try ReceiptComposer.compose(photos: photos, sessionIdentifier: id, date: createdAt, galleryURL: url, format: format)
        let raster = try ThermalImageRasterizer.rasterize(XCTUnwrap(UIImage(data: receipt.imagePNGData)), purpose: .completeReceipt)
        let thumbnails = photos.compactMap { $0.preparingThumbnail(of: CGSize(width: 120, height: 160))?.jpegData(compressionQuality: 0.7) }
        try store.save(RecentSessionArchivePayload(committedSession: committed, composedReceipt: receipt, receiptPreviewPNGData: receipt.imagePNGData, thermalPreviewPNGData: raster.previewPNGData, rasterizedImage: raster, photoThumbnailData: thumbnails))
        return (url, raster)
    }

    private func decodeQR(_ image: UIImage) throws -> String? {
        let ciImage = try XCTUnwrap(CIImage(image: image))
        let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
        return (detector?.features(in: ciImage).first as? CIQRCodeFeature)?.messageString
    }

    func testArchivedQRIsTheExactFrozenURLForLegacyAndCurrentFrontDoors() throws {
        let store = try RecentSessionArchiveStore(directoryURL: root)
        for (token, base, id) in [(String(repeating: "3", count: 64), legacyBase, "PP-20260907-090005"), (String(repeating: "4", count: 64), madeToKeepBase, "PP-20260907-090006")] {
            let (url, raster) = try saveArchive(store: store, token: token, base: base, id: id)
            let archive = try store.load(archiveID: token)
            let link = ArchivedGalleryLink(galleryURL: archive.galleryURL, galleryToken: archive.galleryToken)
            XCTAssertEqual(link.url, url, "The archived URL is used as-is, never rebuilt from today's front door")
            let qr = try XCTUnwrap(link.makeQRImage())
            XCTAssertEqual(try decodeQR(qr), url.absoluteString, "QR scans to exactly the original link")
            // White quiet zone around the matrix.
            let cg = try XCTUnwrap(qr.cgImage)
            XCTAssertEqual(ScreenStats.pixel(cg, x: 2, y: 2), [255, 255, 255])
            XCTAssertEqual(ScreenStats.pixel(cg, x: cg.width - 3, y: cg.height - 3), [255, 255, 255])
            // Showing the QR never touches the archive or its reprint fingerprint.
            let reloaded = try store.load(archiveID: token)
            XCTAssertEqual(reloaded.galleryURL, url)
            XCTAssertEqual(reloaded.summary.rasterFingerprint, RecentSessionArchiveStore.rasterFingerprint(for: raster))
        }
    }

    func testInvalidOrForeignArchivedURLsNeverProduceAQR() throws {
        let token = String(repeating: "5", count: 64)
        let other = String(repeating: "6", count: 64)
        let cases = [
            URL(string: madeToKeepBase + "?g=" + other)!,                        // another customer's token
            URL(string: "http://gallery.madetokeep.test/?g=" + token)!,          // not HTTPS
            URL(string: "https://script.google.com/macros/s/X/exec?g=" + token)!, // Apps Script direct
            URL(string: madeToKeepBase + "?g=" + token + "&x=1")!,               // extra parameters
            URL(string: madeToKeepBase)!                                         // no token
        ]
        for url in cases {
            let link = ArchivedGalleryLink(galleryURL: url, galleryToken: token)
            XCTAssertNil(link.url, url.absoluteString)
            XCTAssertNil(link.makeQRImage())
            XCTAssertEqual(ArchivedGalleryStatus.resolve(linkIsValid: link.isValid, pendingItem: nil, verifiedAt: Date()), .invalidLink)
        }
        XCTAssertNil(ArchivedGalleryLink(galleryURL: URL(string: madeToKeepBase + "?g=" + token)!, galleryToken: "not-a-token").url)
    }

    func testGalleryStatusIsTruthful() {
        XCTAssertEqual(ArchivedGalleryStatus.resolve(linkIsValid: true, pendingItem: nil, verifiedAt: Date()), .verified)
        XCTAssertEqual(ArchivedGalleryStatus.resolve(linkIsValid: true, pendingItem: nil, verifiedAt: nil), .unknown, "Never claims an unverified link is ready")
        let token = String(repeating: "7", count: 64)
        func pending(_ state: GalleryDeliveryState) -> GalleryPendingUploadSummary {
            GalleryPendingUploadSummary(galleryToken: token, galleryURL: URL(string: madeToKeepBase + "?g=" + token)!, sessionID: "PP-1", createdAt: "", deliveryState: state,
                                        metrics: GalleryPreparedUploadMetrics(files: [], totalDecodedBytes: 0, estimatedBase64JSONBytes: 0), payloadSizeBytes: 0, retryAttemptCount: 0, lastAttemptAt: nil, lastSafeError: nil)
        }
        XCTAssertEqual(ArchivedGalleryStatus.resolve(linkIsValid: true, pendingItem: pending(.notStarted), verifiedAt: nil), .waiting("Waiting to upload"))
        XCTAssertEqual(ArchivedGalleryStatus.resolve(linkIsValid: true, pendingItem: pending(.posted), verifiedAt: nil), .uploading)
        XCTAssertEqual(ArchivedGalleryStatus.resolve(linkIsValid: true, pendingItem: pending(.deliveryUnknown), verifiedAt: nil), .needsAttention("Delivery unknown; retry safely"))
        // A queued item outranks an older verification: the queue is the live truth.
        XCTAssertEqual(ArchivedGalleryStatus.resolve(linkIsValid: true, pendingItem: pending(.notStarted), verifiedAt: Date()), .waiting("Waiting to upload"))
        for status in [ArchivedGalleryStatus.verified, .waiting("x"), .needsAttention("x"), .unknown, .invalidLink] {
            XCTAssertFalse(status.detail.contains("http"), "Status copy never embeds a URL")
        }
        XCTAssertTrue(ArchivedGalleryStatus.waiting("Waiting to upload").detail.contains("may not be ready"))
    }

    func testPrintSummaryIsConciseAndFlagsUnknownOutcomes() {
        XCTAssertEqual(ArchivedPrintSummary.resolve(records: []), .notRecorded)
        XCTAssertEqual(ArchivedPrintSummary.notRecorded.title, "Print not recorded")
        XCTAssertTrue(ArchivedPrintSummary.needsInspection.isAttention)
        XCTAssertEqual(ArchivedPrintSummary.printed(copies: 2).title, "Printed · 2 copies")
    }

    func testSearchGroupingFiltersAndCorruptArchivesInTheCollection() async throws {
        let store = try RecentSessionArchiveStore(directoryURL: root)
        let calendar = Calendar.current
        let yesterday = calendar.date(byAdding: .day, value: -1, to: Date())!
        _ = try saveArchive(store: store, token: String(repeating: "a", count: 64), base: madeToKeepBase, id: "PP-20261020-010101", format: .grid)
        _ = try saveArchive(store: store, token: String(repeating: "b", count: 64), base: legacyBase, id: "PP-20261019-020202", format: .solo, createdAt: yesterday)
        let corrupt = root.appendingPathComponent(String(repeating: "c", count: 64))
        try FileManager.default.createDirectory(at: corrupt, withIntermediateDirectories: true)
        try Data("{".utf8).write(to: corrupt.appendingPathComponent("metadata.json"))

        let model = RecentSessionsViewModel(store: store)
        model.refresh()
        let deadline = Date().addingTimeInterval(10)
        while !model.hasLoaded, Date() < deadline { try await Task.sleep(for: .milliseconds(30)) }
        XCTAssertEqual(model.summaries.count, 3)
        XCTAssertEqual(model.groupedSummaries.first?.0, "Today")
        XCTAssertTrue(model.groupedSummaries.map(\.0).contains("Yesterday"))
        XCTAssertEqual(model.groupedSummaries.last?.0, RecentSessionsViewModel.unreadableSectionTitle, "Corrupt archives are grouped last, never under a fake date")
        let before = await model.thumbnails.statistics()
        XCTAssertEqual(before.count, 0, "Metadata must not wait for thumbnail decoding")
        let visible = try XCTUnwrap(model.summaries.first { $0.rasterFingerprint != "CORRUPT" })
        let image = await model.thumbnail(for: visible)
        XCTAssertNotNil(image, "Visible previews decode asynchronously off the main thread")
        model.formatFilter = .solo
        XCTAssertEqual(model.filteredSummaries.map(\.sessionIdentifier), ["PP-20261019-020202"])
        model.formatFilter = nil
        model.showsOnlyAttention = true
        XCTAssertTrue(model.filteredSummaries.contains { $0.rasterFingerprint == "CORRUPT" }, "Corrupt archives surface under Needs attention")
        model.showsOnlyAttention = false
        model.searchText = "grid"
        XCTAssertEqual(model.filteredSummaries.map(\.sessionIdentifier), ["PP-20261020-010101"])
        model.searchText = ""

        // Screens: collection and detail in both orientations.
        for size in [Self.portrait, Self.landscape] {
            let suffix = size.width < size.height ? "portrait" : "landscape"
            let list = try await ScreenshotHarness.render(NavigationStack { RecentSessionsCollectionHarness(model: model) }, size: size, scene: scene, settle: .milliseconds(700))
            add(ScreenshotHarness.attachment(list, name: "recent-sessions-\(suffix)"))
            try EmojiStickerTests.dump(list.pngData(), name: "recent-sessions-\(suffix).png")
            let summary = try XCTUnwrap(model.summaries.first { $0.format == .grid })
            let detail = try await ScreenshotHarness.render(NavigationStack { ArchivedSessionDetailView(summary: summary, rootViewModel: model) }, size: size, scene: scene, settle: .milliseconds(1500))
            add(ScreenshotHarness.attachment(detail, name: "recent-session-detail-\(suffix)"))
            try EmojiStickerTests.dump(detail.pngData(), name: "recent-session-detail-\(suffix).png")
        }
    }

    func testRecentSessionsSourceNeverLogsAFullGalleryTokenOrURL() throws {
        let source = try String(contentsOf: Self.sourceURL("RecentSessionsView.swift"), encoding: .utf8)
        for line in source.split(separator: "\n") where line.contains("debugLog(") || line.contains("print(") {
            XCTAssertFalse(line.contains("galleryURL"), String(line))
            XCTAssertFalse(line.contains("galleryToken"), String(line))
            if line.contains("archive=") { XCTAssertTrue(line.contains("redacted(archiveID)"), String(line)) }
        }
    }

    // MARK: Zoomable receipt viewer

    private func tallReceipt(width: Int = 576, height: Int = 6_000) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            UIColor.black.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: 40))
            context.fill(CGRect(x: 0, y: height - 40, width: width, height: 40))
        }
    }

    func testZoomViewFitsWholeExtremeReceiptAndPresetsAreRelativeToFit() throws {
        let image = tallReceipt()
        let original = image.pngData()
        let view = ReceiptZoomScrollView(frame: CGRect(x: 0, y: 0, width: 420, height: 700))
        view.display(image, rendering: .exactRaster)
        view.layoutIfNeeded()
        let fit = view.fitScale
        XCTAssertEqual(fit, 700.0 / 6_000.0, accuracy: 0.0001, "Height-limited: top and bottom both visible")
        XCTAssertEqual(view.zoomScale, fit, accuracy: 0.0001)
        XCTAssertLessThanOrEqual(view.contentSize.height, view.bounds.height + 0.5)
        XCTAssertLessThanOrEqual(view.contentSize.width, view.bounds.width + 0.5)
        XCTAssertEqual(view.contentSize.width / view.contentSize.height, 576.0 / 6_000.0, accuracy: 0.001, "Aspect preserved, no stretch")
        XCTAssertFalse(view.panGestureRecognizer.isEnabled, "At Fit the parent scroll view keeps its gestures")
        XCTAssertEqual(view.imageView.layer.magnificationFilter, .nearest, "Exact raster dots stay crisp")

        for preset in [1.5, 2, 3] as [CGFloat] {
            view.zoom(toRelative: preset, animated: false)
            XCTAssertEqual(view.zoomScale / fit, preset, accuracy: 0.01)
            XCTAssertTrue(view.panGestureRecognizer.isEnabled)
        }
        view.zoom(toRelative: 50, animated: false)
        XCTAssertEqual(view.zoomScale / fit, OperatorZoomableReceiptView.maximumZoom, accuracy: 0.01, "Bounded maximum")
        view.zoom(toRelative: 1, animated: false)
        XCTAssertEqual(view.zoomScale, fit, accuracy: 0.0001, "Reset returns to Fit")

        // Rotation / resize keeps the whole receipt visible at Fit.
        view.frame = CGRect(x: 0, y: 0, width: 900, height: 500)
        view.layoutIfNeeded()
        XCTAssertEqual(view.fitScale, 500.0 / 6_000.0, accuracy: 0.0001)
        XCTAssertLessThanOrEqual(view.contentSize.height, 500.5)

        XCTAssertTrue(view.imageView.image === image)
        XCTAssertEqual(image.pngData(), original, "Display-only zoom never changes the source image")

        let smooth = ReceiptZoomScrollView(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        smooth.display(tallReceipt(width: 576, height: 900), rendering: .smooth)
        smooth.layoutIfNeeded()
        XCTAssertEqual(smooth.imageView.layer.magnificationFilter, .linear)
    }

    func testZoomingAnArchivedReceiptKeepsTheReprintFingerprint() async throws {
        let store = try RecentSessionArchiveStore(directoryURL: root)
        let token = String(repeating: "d", count: 64)
        let (_, raster) = try saveArchive(store: store, token: token, base: madeToKeepBase, id: "PP-20261020-030303", format: .gridSix)
        let before = try store.load(archiveID: token)
        let receipt = try XCTUnwrap(UIImage(data: before.receiptPreviewPNGData))
        let view = ReceiptZoomScrollView(frame: CGRect(x: 0, y: 0, width: 400, height: 640))
        view.display(receipt, rendering: .smooth)
        view.layoutIfNeeded()
        view.zoom(toRelative: 3, animated: false)
        view.zoom(toRelative: 1, animated: false)
        let after = try store.load(archiveID: token)
        XCTAssertEqual(after.summary.rasterFingerprint, before.summary.rasterFingerprint)
        XCTAssertEqual(after.rasterizedImage.rasterCommand, raster.rasterCommand)
        XCTAssertEqual(after.receiptPreviewPNGData, before.receiptPreviewPNGData)
        XCTAssertEqual(RecentSessionArchiveStore.rasterFingerprint(for: after.rasterizedImage), before.summary.rasterFingerprint)
    }

    func testGestureOnlyZoomViewerFitsWithAVeryTallReceipt() async throws {
        let image = tallReceipt(width: 576, height: 9_000)
        let view = OperatorZoomableReceiptView(image: image, rendering: .exactRaster).frame(width: 300, height: 560).padding()
        let rendered = try await ScreenshotHarness.render(view.background(Color.white), size: CGSize(width: 340, height: 620), scene: scene)
        add(ScreenshotHarness.attachment(rendered, name: "zoom-viewer-narrow"))
        try EmojiStickerTests.dump(rendered.pngData(), name: "zoom-viewer-narrow.png")
        let wide = OperatorZoomableReceiptView(image: image, rendering: .exactRaster).frame(width: 520, height: 700).padding()
        let renderedWide = try await ScreenshotHarness.render(wide.background(Color.white), size: CGSize(width: 560, height: 760), scene: scene)
        try EmojiStickerTests.dump(renderedWide.pngData(), name: "zoom-viewer-wide.png")
    }

    // MARK: Helpers

    static func sourceURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("PocketPixelsBooth").appendingPathComponent(name)
    }
}

/// Renders the collection for an already-loaded model (RecentSessionsView owns its own model).
private struct RecentSessionsCollectionHarness: View {
    @ObservedObject var model: RecentSessionsViewModel

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                ForEach(model.groupedSummaries, id: \.0) { title, summaries in
                    Text(title).font(MadeToKeepTheme.Typography.italicSerif(size: 28)).foregroundStyle(OperatorPalette.accent)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 330, maximum: 560), spacing: 16)], spacing: 16) {
                        ForEach(summaries) { RecentSessionRow(summary: $0, viewModel: model) }
                    }
                }
            }
            .padding(24)
        }
        .background(OperatorPalette.canvas)
        .navigationTitle("Recent Sessions")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Coarse screen colour statistics.
struct ScreenStats {
    var burgundyFraction = 0.0

    init(_ image: UIImage) {
        guard let cg = image.cgImage, let context = EmojiStickerRenderer.rgbaContext(width: cg.width, height: cg.height) else { return }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        guard let data = context.data else { return }
        let pixels = data.bindMemory(to: UInt8.self, capacity: cg.width * cg.height * 4)
        var burgundy = 0, total = 0
        for index in stride(from: 0, to: cg.width * cg.height, by: 7) {
            let r = Int(pixels[index * 4]), g = Int(pixels[index * 4 + 1]), b = Int(pixels[index * 4 + 2])
            total += 1
            if r > 80, r < 160, g < 50, b < 60 { burgundy += 1 }
        }
        burgundyFraction = Double(burgundy) / Double(max(1, total))
    }

    static func pixel(_ image: CGImage, x: Int, y: Int) -> [UInt8] {
        let context = EmojiStickerRenderer.rgbaContext(width: image.width, height: image.height)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let pixels = context.data!.bindMemory(to: UInt8.self, capacity: image.width * image.height * 4)
        let offset = (y * image.width + x) * 4
        return [pixels[offset], pixels[offset + 1], pixels[offset + 2]]
    }
}
