import XCTest
import UIKit
@testable import PocketPixelsBooth

@MainActor final class ReceiptSessionIdentifierTests: XCTestCase {
    private let full = "PP-20261029-044046-03858c82-dd83-4fab-9ffe-4032106883c5"
    private let printed = "PP-20261029-044046"
    private let date = Date(timeIntervalSince1970: 1_793_220_046)

    func testOnlyCanonicalTimestampAndUUIDIdentifiersAreShortened() {
        XCTAssertEqual(ReceiptComposer.displayedSessionIdentifier(full), printed)
        XCTAssertEqual(ReceiptComposer.displayedSessionIdentifier(full.uppercased()), printed)
        for legacy in ["", printed, "PP-GRID6-ARCHIVE", "operator-sample", "客人-123", full + "\n", full + "-extra",
                       "PP-20261029-044046-not-a-valid-uuid-suffix", "PP-20260230-044046-03858c82-dd83-4fab-9ffe-4032106883c5",
                       "PP-20261029-254046-03858c82-dd83-4fab-9ffe-4032106883c5"] {
            XCTAssertEqual(ReceiptComposer.displayedSessionIdentifier(legacy), legacy)
        }
    }

    func testEveryFormatRendersTheShortTextWithoutChangingInternalIdentityOrLayout() throws {
        let gallery = URL(string: "https://example.test/original-gallery")!
        for format in BoothFormat.allCases {
            let photos = (0..<format.photoCount).map { ReliabilityFixtures.syntheticPhoto(session: 29, photo: $0, format: format) }
            let passport: PassportSessionData? = format == .passport ? .photoPassDebugFixture : nil
            let originalID = try ReceiptComposer.compose(photos: photos, sessionIdentifier: full, date: date,
                galleryURL: gallery, format: format, passport: passport)
            let shortID = try ReceiptComposer.compose(photos: photos, sessionIdentifier: printed, date: date,
                galleryURL: gallery, format: format, passport: passport)
            XCTAssertEqual(originalID.sessionIdentifier, full)
            XCTAssertEqual(originalID.imagePNGData, shortID.imagePNGData, "The rendered bottom ID must equal the printed prefix: \(format)")
            XCTAssertEqual(originalID.width, shortID.width)
            XCTAssertEqual(originalID.height, shortID.height)
            XCTAssertEqual(originalID.previewContentHeight, shortID.previewContentHeight)
            XCTAssertEqual(originalID.includesPrintedGalleryQR, shortID.includesPrintedGalleryQR)
        }
        let environment = BoothSessionEnvironment.customer
        let first = environment.makeSessionIdentifier(date), second = environment.makeSessionIdentifier(date)
        XCTAssertNotEqual(first, second, "Session generation must remain UUID-backed even at the same second")
        XCTAssertEqual(ReceiptComposer.displayedSessionIdentifier(first), ReceiptComposer.makeSessionIdentifier(date: date))
    }

    func testSamplesStillOmitTheIdentifier() throws {
        let photos = [ReliabilityFixtures.syntheticPhoto(session: 30, photo: 0, format: .solo)]
        let sample = try ReceiptComposer.compose(photos: photos, sessionIdentifier: full, date: date, format: .solo, printsSessionIdentifier: false)
        let blank = try ReceiptComposer.compose(photos: photos, sessionIdentifier: "", date: date, format: .solo, printsSessionIdentifier: false)
        XCTAssertEqual(sample.imagePNGData, blank.imagePNGData)
        XCTAssertEqual(sample.sessionIdentifier, full)
    }

    func testPrintedPrefixFindsFullArchivedIdentitiesAndFrozenLegacyReprintBytesStayUnchanged() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("receipt-id-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try RecentSessionArchiveStore(directoryURL: root)
        let photos = [ReliabilityFixtures.syntheticPhoto(session: 31, photo: 0, format: .solo)]
        // A previously saved bitmap with the full printed ID. Reprints use these bytes directly.
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let oldImage = UIGraphicsImageRenderer(size: CGSize(width: 576, height: 96), format: format).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 576, height: 96))
            (full as NSString).draw(at: CGPoint(x: 16, y: 40), withAttributes: [.font: UIFont.monospacedSystemFont(ofSize: 10, weight: .regular), .foregroundColor: UIColor.black])
        }
        let oldPNG = try XCTUnwrap(oldImage.pngData())
        let oldRaster = try ThermalImageRasterizer.rasterize(oldImage, purpose: .completeReceipt)
        let ids = [full, "\(printed)-a3b02330-80aa-45f3-bcc4-b00d962d163b"]
        for (index, id) in ids.enumerated() {
            let token = String(repeating: index == 0 ? "a" : "b", count: 64)
            let session = CommittedGallerySession(sessionIdentifier: id, createdAt: date, galleryToken: token,
                galleryURL: URL(string: "https://example.test/\(token)")!, photos: photos, format: .solo, eventProfile: nil)
            let saved = ComposedReceipt(imagePNGData: oldPNG, width: 576, height: 96, previewContentHeight: 96,
                sessionIdentifier: id, createdAt: date, format: .solo, photoQualityProfile: .customerPrintDefault)
            try store.save(.init(committedSession: session, composedReceipt: saved, receiptPreviewPNGData: oldPNG,
                thermalPreviewPNGData: oldRaster.previewPNGData, rasterizedImage: oldRaster, photoThumbnailData: []))
        }
        _ = try ReceiptComposer.compose(photos: photos, sessionIdentifier: full, date: date, format: .solo)
        let reopened = try RecentSessionArchiveStore(directoryURL: root)
        let archive = try reopened.load(archiveID: String(repeating: "a", count: 64))
        XCTAssertEqual(archive.summary.sessionIdentifier, full)
        XCTAssertEqual(archive.receiptPreviewPNGData, oldPNG)
        XCTAssertEqual(archive.rasterizedImage.rasterCommand, oldRaster.rasterCommand)
        func envelope(_ raster: ThermalRasterizedImage) throws -> PrintJobEnvelope {
            try .receipt(rasterizedImage: raster, sessionIdentifier: full, source: .archivedReprint,
                copyIndex: 1, copyCount: 1, batchID: UUID(), transportPolicy: .safeIntegrity)
        }
        XCTAssertEqual(try envelope(archive.rasterizedImage).payload, try envelope(oldRaster).payload)
        XCTAssertEqual(try envelope(archive.rasterizedImage).sessionIdentifier, full)
        let model = RecentSessionsViewModel(store: reopened)
        model.scope = .allHistory; model.searchText = printed; model.refresh()
        for _ in 0..<500 {
            if model.hasLoaded { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(model.hasLoaded)
        XCTAssertEqual(Set(model.filteredSummaries.map(\.sessionIdentifier)), Set(ids))
    }
}
