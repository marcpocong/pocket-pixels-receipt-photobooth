import XCTest
import ImageIO
import SwiftUI
@testable import PocketPixelsBooth

@MainActor enum V41ArchiveFixture {
    static func payload(token: String = String(repeating: "a", count: 64), sessionID: String = "PP-20261025-120000") throws -> RecentSessionArchivePayload {
        let photo = ReliabilityFixtures.syntheticPhoto(session: 41, photo: 1, format: .solo)
        let url = try GalleryURLBuilder.makeGalleryURL(customerGalleryBaseURL: URL(string: "https://synthetic.example.test")!, galleryToken: token)
        let session = CommittedGallerySession(sessionIdentifier: sessionID, createdAt: Date(), galleryToken: token, galleryURL: url, photos: [photo], format: .solo, eventProfile: nil)
        let receipt = try ReceiptComposer.compose(photos: [photo], sessionIdentifier: sessionID, date: session.createdAt, galleryURL: url, format: .solo)
        let raster = try ThermalImageRasterizer.rasterize(XCTUnwrap(UIImage(data: receipt.imagePNGData)), purpose: .completeReceipt)
        return .init(committedSession: session, composedReceipt: receipt, receiptPreviewPNGData: receipt.imagePNGData,
            thermalPreviewPNGData: raster.previewPNGData, rasterizedImage: raster, photoThumbnailData: [try SessionArchiveCommitter.thumbnailData(from: photo)])
    }
}

private actor V41PhotosWriter: PhotosLibraryWriting {
    let allowed: Bool
    let fails: Bool
    let delay: Bool
    var saved: [[Data]] = []
    init(allowed: Bool = true, fails: Bool = false, delay: Bool = false) { self.allowed = allowed; self.fails = fails; self.delay = delay }
    func requestAddAccess() async -> Bool { allowed }
    func save(files: [URL]) async throws {
        if delay { try await Task.sleep(for: .milliseconds(80)) }
        if fails { throw CocoaError(.fileWriteOutOfSpace) }
        saved.append(try files.map { try Data(contentsOf: $0) })
    }
}

@MainActor final class OperatorWorkspaceV41MediaTests: XCTestCase {
    private var root: URL!
    override func setUp() async throws { root = FileManager.default.temporaryDirectory.appendingPathComponent("v41-media-\(UUID())") }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }
    func testReceiptExportUsesIdenticalArchivedPNGAndDimensions() async throws {
        let store = try RecentSessionArchiveStore(directoryURL: root), payload = try V41ArchiveFixture.payload()
        try store.save(payload)
        let original = try store.load(archiveID: payload.committedSession.galleryToken)
        let writer = V41PhotosWriter()
        try await SessionMediaExport.save(data: [original.receiptPreviewPNGData], writer: writer)
        let saved = await writer.saved
        XCTAssertEqual(saved, [[payload.receiptPreviewPNGData]])
        let source = try XCTUnwrap(CGImageSourceCreateWithData(saved[0][0] as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, original.summary.receiptWidth)
        XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, original.summary.receiptHeight)
        XCTAssertEqual(try store.load(archiveID: original.summary.archiveID).rasterizedImage.rasterCommand, original.rasterizedImage.rasterCommand)
    }
    func testOriginalRetentionPreservesEncodedBytesOrderAndSurvivesRelaunch() async throws {
        let store = try RecentSessionArchiveStore(directoryURL: root), payload = try V41ArchiveFixture.payload()
        try store.save(payload)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let highResolution = UIGraphicsImageRenderer(size: CGSize(width: 1200, height: 1600), format: format).image { _ in }
        let bytes = try XCTUnwrap(highResolution.jpegData(compressionQuality: 0.93))
        try store.attachOriginalPhotos(archiveID: payload.committedSession.galleryToken, sessionID: payload.committedSession.sessionIdentifier, photos: [bytes])
        let before = try store.originalPhotoStorageBytes()
        try store.attachOriginalPhotos(archiveID: payload.committedSession.galleryToken, sessionID: payload.committedSession.sessionIdentifier, photos: [bytes])
        XCTAssertEqual(try store.originalPhotoStorageBytes(), before)
        let reopened = try RecentSessionArchiveStore(directoryURL: root)
        let sources = try SessionMediaExport.photos(archive: reopened.load(archiveID: payload.committedSession.galleryToken), store: reopened)
        XCTAssertEqual(sources.map(\.quality), [.original]); XCTAssertEqual(sources.map(\.data), [bytes]); XCTAssertEqual(sources.map(\.id), [0])
        let writer = V41PhotosWriter()
        try await SessionMediaExport.save(data: sources.map(\.data), writer: writer)
        let saved = await writer.saved; XCTAssertEqual(saved, [[bytes]])
        XCTAssertThrowsError(try store.originalPhotos(archiveID: payload.committedSession.galleryToken, sessionID: "another-guest"))
        XCTAssertGreaterThan(before, bytes.count)
    }
    func testHistoricalPreparedAndThumbnailSourcesAreNeverLabelledOriginal() throws {
        let store = try RecentSessionArchiveStore(directoryURL: root.appendingPathComponent("archive")), payload = try V41ArchiveFixture.payload()
        try store.save(payload)
        let archive = try store.load(archiveID: payload.committedSession.galleryToken)
        XCTAssertEqual(try SessionMediaExport.photos(archive: archive, store: store).map(\.quality), [.thumbnail])
        let queue = try GalleryPendingUploadStore(directoryURL: root.appendingPathComponent("queue"))
        let prepared = try GoogleDriveGalleryUploadService.preparePayload(photos: payload.committedSession.photos, composedReceipt: payload.committedSession.photos[0],
            sessionID: payload.committedSession.sessionIdentifier, createdAt: Date(), galleryToken: payload.committedSession.galleryToken,
            customerGalleryBaseURL: URL(string: "https://synthetic.example.test")!)
        try queue.save(prepared)
        XCTAssertEqual(try SessionMediaExport.photos(archive: archive, store: store, pending: queue).map(\.quality), [.prepared])
        XCTAssertEqual(try queue.load(galleryToken: archive.galleryToken)?.photos.map(\.data), prepared.photos.map(\.data))
    }
    func testDeniedRestrictedStorageAndTransactionFailuresNeverClaimSuccess() async throws {
        let bytes = try XCTUnwrap(ReliabilityFixtures.syntheticPhoto(session: 1, photo: 1, format: .solo).pngData())
        for deniedOrRestricted in 0..<2 {
            let writer = V41PhotosWriter(allowed: false)
            do { try await SessionMediaExport.save(data: [bytes], writer: writer); XCTFail("\(deniedOrRestricted)") }
            catch { XCTAssertEqual(error.localizedDescription, MediaExportError.permission.localizedDescription) }
            let saved = await writer.saved; XCTAssertTrue(saved.isEmpty)
        }
        let writer = V41PhotosWriter(fails: true)
        do { try await SessionMediaExport.save(data: [bytes], writer: writer); XCTFail() }
        catch { XCTAssertEqual(error.localizedDescription, MediaExportError.saveFailed.localizedDescription) }
        do { try await SessionMediaExport.save(data: [], writer: writer); XCTFail() } catch { }
    }
    func testSeveralPhotosSaveTogetherAndRepeatedTapDoesNotStartAnotherTransaction() async throws {
        let bytes = try XCTUnwrap(ReliabilityFixtures.syntheticPhoto(session: 1, photo: 1, format: .solo).pngData())
        let writer = V41PhotosWriter()
        try await SessionMediaExport.save(data: [bytes, bytes, bytes], writer: writer)
        let saved = await writer.saved; XCTAssertEqual(saved, [[bytes, bytes, bytes]])
        let store = try RecentSessionArchiveStore(directoryURL: root), payload = try V41ArchiveFixture.payload()
        try store.save(payload)
        let slowWriter = V41PhotosWriter(delay: true)
        let model = RecentSessionsViewModel(store: store, photosWriter: slowWriter)
        model.exportReceipt(payload.committedSession.galleryToken); model.exportReceipt(payload.committedSession.galleryToken)
        XCTAssertTrue(model.isExporting)
        while model.isExporting { try await Task.sleep(for: .milliseconds(10)) }
        let transactions = await slowWriter.saved; XCTAssertEqual(transactions.count, 1)
        XCTAssertEqual(model.exportMessage, "Receipt saved to Photos")
        XCTAssertNotNil(try store.summary(archiveID: payload.committedSession.galleryToken))
    }
    func testDeletionIsIdempotentAndLateArchiveCallbacksCannotRecreateMedia() throws {
        let store = try RecentSessionArchiveStore(directoryURL: root), payload = try V41ArchiveFixture.payload()
        let id = payload.committedSession.galleryToken
        try store.save(payload); try store.setHidden(archiveID: id, hidden: true)
        XCTAssertTrue(try store.summaries()[0].isHidden)
        try store.setHidden(archiveID: id, hidden: false); XCTAssertFalse(try store.summaries()[0].isHidden)
        try store.delete(archiveID: id); try store.delete(archiveID: id)
        XCTAssertTrue(try RecentSessionArchiveStore(directoryURL: root).summaries().isEmpty)
        XCTAssertThrowsError(try store.save(payload))
        XCTAssertThrowsError(try store.attachThumbnails(archiveID: id, thumbnails: payload.photoThumbnailData))
        XCTAssertThrowsError(try store.attachOriginalPhotos(archiveID: id, sessionID: payload.committedSession.sessionIdentifier, photos: [payload.receiptPreviewPNGData]))
    }
    func testInterruptedDeletionFinishesOnRelaunchAndBadStorageIsNotSuccess() throws {
        let store = try RecentSessionArchiveStore(directoryURL: root), payload = try V41ArchiveFixture.payload()
        try store.save(payload)
        let markers = root.appendingPathComponent(".deleted")
        try FileManager.default.createDirectory(at: markers, withIntermediateDirectories: true)
        try DurableFileWriter.write(Data("deleted-v1".utf8), to: markers.appendingPathComponent(payload.committedSession.galleryToken))
        let reopened = try RecentSessionArchiveStore(directoryURL: root)
        XCTAssertTrue(try reopened.summaries().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(payload.committedSession.galleryToken).path))
        let other = String(repeating: "b", count: 64)
        try FileManager.default.removeItem(at: markers)
        try Data([1]).write(to: markers)
        XCTAssertThrowsError(try store.delete(archiveID: other))
    }
    func testChangingZoomedShortAndLongImagesResetsToWholeImageFit() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let images = [1000, 9000, 800].map { height in
            UIGraphicsImageRenderer(size: CGSize(width: 576, height: height), format: format).image { context in
                UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 576, height: height))
            }
        }
        let originals = images.map { $0.pngData() }
        let view = ReceiptZoomScrollView(frame: CGRect(x: 0, y: 0, width: 500, height: 700))
        for image in images {
            view.display(image, rendering: .smooth); view.layoutIfNeeded()
            XCTAssertEqual(view.zoomScale, view.fitScale, accuracy: 0.001)
            XCTAssertLessThanOrEqual(view.imageView.frame.width, view.bounds.width + 1)
            XCTAssertLessThanOrEqual(view.imageView.frame.height, view.bounds.height + 1)
            XCTAssertFalse(view.panGestureRecognizer.isEnabled)
            view.zoom(toRelative: 3, animated: false)
            XCTAssertTrue(view.panGestureRecognizer.isEnabled)
        }
        XCTAssertEqual(images.map { $0.pngData() }, originals)
    }

    func testTargetedThumbnailEvictionRetainsUnrelatedCacheEntries() async throws {
        let store = try RecentSessionArchiveStore(directoryURL: root), payload = try V41ArchiveFixture.payload()
        let second = try V41ArchiveFixture.payload(token: String(repeating: "b", count: 64), sessionID: "PP-other")
        try store.save(payload); try store.save(second)
        let cache = SessionThumbnailCache()
        _ = await cache.image(archiveID: payload.committedSession.galleryToken, filename: try XCTUnwrap(store.summary(archiveID: payload.committedSession.galleryToken)?.thumbnailFilenames.first), store: store)
        _ = await cache.image(archiveID: second.committedSession.galleryToken, filename: try XCTUnwrap(store.summary(archiveID: second.committedSession.galleryToken)?.thumbnailFilenames.first), store: store)
        let warm = await cache.statistics(); XCTAssertEqual(warm.count, 2)
        await cache.remove(archiveID: payload.committedSession.galleryToken)
        let stats = await cache.statistics(); XCTAssertEqual(stats.count, 1)
    }
}


extension OperatorWorkspaceV41MediaTests {
    func testUnresolvedRetentionWarningSurvivesSuccessfulUnrelatedExportAndFeedbackDismissal() async throws {
        let store = try RecentSessionArchiveStore(directoryURL: root), payload = try V41ArchiveFixture.payload()
        try store.save(payload)
        let model = RecentSessionsViewModel(store: store, photosWriter: V41PhotosWriter())
        NotificationCenter.default.post(name: .originalPhotoRetentionFailed, object: nil)
        for _ in 0..<50 where model.retentionFailure == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(model.retentionFailure?.isError == true)
        model.exportReceipt(payload.committedSession.galleryToken)
        while model.isExporting { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.actionFeedback?.message, "Receipt saved to Photos")
        model.dismissFeedback()
        XCTAssertNil(model.actionFeedback)
        XCTAssertTrue(model.retentionFailure?.isError == true, "An unrelated routine success must never clear an unresolved media-retention warning")
    }
}
