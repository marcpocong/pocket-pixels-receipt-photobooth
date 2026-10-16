import XCTest
import SwiftUI
@testable import PocketPixelsBooth

@MainActor final class EventRunArchiveAndLayoutTests: XCTestCase {
    private var root: URL!
    override func setUp() { root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }
    private func library(authorized: @escaping @MainActor () -> Bool = { true }, blocked: @escaping @MainActor () -> String? = { nil }) -> EventDesignLibraryStore {
        EventDesignLibraryStore(directory: root.appendingPathComponent("designs"), legacyProfile: { .pocketPixelsDefault }, legacyName: { "" }, operationAuthorized: authorized, operationBlockingReason: blocked)
    }
    private func payload() throws -> RecentSessionArchivePayload {
        let photo = ReliabilityFixtures.syntheticPhoto(session: 923, photo: 0, format: .solo)
        let token = String(repeating: "e", count: 64)
        let session = CommittedGallerySession(sessionIdentifier: "synthetic-archive", createdAt: Date(), galleryToken: token,
            galleryURL: URL(string: "https://synthetic.example.test/?g=" + token)!, photos: [photo], format: .solo, eventProfile: nil)
        let receipt = try ReceiptComposer.compose(photos: [photo], sessionIdentifier: session.sessionIdentifier, date: session.createdAt, galleryURL: session.galleryURL, format: .solo)
        let raster = try ThermalImageRasterizer.rasterize(XCTUnwrap(UIImage(data: receipt.imagePNGData)), purpose: .completeReceipt)
        return RecentSessionArchivePayload(committedSession: session, composedReceipt: receipt, receiptPreviewPNGData: receipt.imagePNGData,
            thermalPreviewPNGData: raster.previewPNGData, rasterizedImage: raster, photoThumbnailData: [], eventRunID: "exact-run", eventDesignID: "exact-design")
    }
    func testArchiveStoresExactRunAndLegacyMetadataLoadsWithoutRewritingOrInference() throws {
        let directory = root.appendingPathComponent("archive")
        let store = try RecentSessionArchiveStore(directoryURL: directory)
        let payload = try payload()
        try store.save(payload)
        XCTAssertEqual(try store.summaries().first?.eventRunID, "exact-run")
        XCTAssertEqual(try store.summaries().first?.eventDesignID, "exact-design")
        let file = directory.appendingPathComponent(payload.committedSession.galleryToken).appendingPathComponent("metadata.json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        json.removeValue(forKey: "eventRunID"); json.removeValue(forKey: "eventDesignID")
        let legacy = try JSONSerialization.data(withJSONObject: json)
        try legacy.write(to: file)
        XCTAssertNil(try store.summaries().first?.eventRunID)
        XCTAssertNil(try store.load(archiveID: payload.committedSession.galleryToken).summary.eventDesignID)
        XCTAssertEqual(try Data(contentsOf: file), legacy)
        XCTAssertThrowsError(try store.save(payload), "A reporting upgrade cannot overwrite a historical receipt")
        XCTAssertEqual(try Data(contentsOf: file), legacy)
    }
    func testAppliedCommerciallyLinkedAndHistoricalDesignsCannotBeDeleted() throws {
        let library = library()
        let applied = try library.create(name: "Applied", venue: "")
        try library.recordApplied(eventModeEnabled: true, eventID: applied.id)
        XCTAssertThrowsError(try library.deleteUnusedDesign(id: applied.id, runs: [], archives: [], historyAvailable: true))
        let commercial = try library.create(name: "Paid", venue: "")
        try library.link(designID: commercial.id, binding: "live:synthetic", serverEventID: "commercial")
        XCTAssertThrowsError(try library.deleteUnusedDesign(id: commercial.id, runs: [], archives: [], historyAvailable: true))
        let historical = try library.create(name: "Historic", venue: "")
        let run = EventRunRecord(id: "run", context: EventRunContext(designID: historical.id, commercialEventID: nil, serverBinding: nil, name: "Historical"), createdAt: Date(), status: .archived)
        XCTAssertThrowsError(try library.deleteUnusedDesign(id: historical.id, runs: [run], archives: [], historyAvailable: true))
        let archiveStore = try RecentSessionArchiveStore(directoryURL: root.appendingPathComponent("archive"))
        var archive = try payload(); archive.eventDesignID = historical.id
        try archiveStore.save(archive)
        XCTAssertThrowsError(try library.deleteUnusedDesign(id: historical.id, runs: [], archives: archiveStore.summaries(), historyAvailable: true))
        XCTAssertEqual(library.library.events.count, 3)
    }
    func testOnlyUnusedDesignCanBeDeletedAndArchiveIsReversible() throws {
        let library = library()
        let design = try library.create(name: "Unused", venue: "")
        try library.archiveDesign(id: design.id)
        XCTAssertNotNil(library.design(id: design.id)?.archivedAt)
        try library.restoreDesign(id: design.id)
        XCTAssertNil(library.design(id: design.id)?.archivedAt)
        XCTAssertThrowsError(try library.deleteUnusedDesign(id: design.id, runs: [], archives: [], historyAvailable: false))
        try library.deleteUnusedDesign(id: design.id, runs: [], archives: [], historyAvailable: true)
        XCTAssertNil(library.design(id: design.id))
    }
    func testDesignCleanupRequiresAuthenticationAndSafeIdle() throws {
        var permitted = true; var reason: String?
        let library = library(authorized: { permitted }, blocked: { reason })
        let design = try library.create(name: "Unused", venue: "")
        permitted = false
        XCTAssertThrowsError(try library.archiveDesign(id: design.id))
        XCTAssertThrowsError(try library.deleteUnusedDesign(id: design.id, runs: [], archives: [], historyAvailable: true))
        permitted = true; reason = "Guest active"
        XCTAssertThrowsError(try library.archiveDesign(id: design.id))
        XCTAssertThrowsError(try library.deleteUnusedDesign(id: design.id, runs: [], archives: [], historyAvailable: true))
        XCTAssertNotNil(library.design(id: design.id))
    }
    func testPrintJournalReconciliationRepairsStatisticsAfterCrashWithoutAdoptingLegacySessions() async throws {
        let store = EventRunStore(directory: root.appendingPathComponent("runs"), authorized: { true }, blockingReason: { nil })
        let run = try store.startNewRun(context: EventRunContext(designID: nil, commercialEventID: nil, serverBinding: nil, name: "Synthetic"))
        try store.beginSession(id: "assigned", runID: run.id, format: "solo")
        let outbox = try PrintOutcomeOutbox(directory: root.appendingPathComponent("outbox"))
        for session in ["assigned", "legacy-unassigned"] {
            try outbox.beginCopy(batchID: session, sessionID: session, entitlementID: nil, receiptFingerprint: String(repeating: "a", count: 64), copyIndex: 1, copyCount: 1, transport: "bluetooth")
            XCTAssertTrue(outbox.finishCopy(batchID: session, copyIndex: 1, state: .delivered))
        }
        await store.reconcilePrintEvidence(outbox.entries)
        let first = try XCTUnwrap(store.session(id: "assigned"))
        XCTAssertNotNil(first.completedAt); XCTAssertEqual(first.printOutcomes["assigned/1"], "delivered")
        XCTAssertNil(try store.session(id: "legacy-unassigned"))
        let revision = store.revision
        await store.reconcilePrintEvidence(outbox.entries)
        XCTAssertEqual(store.revision, revision, "Reconciliation must be idempotent")
    }
    func testRunReportRendersPortraitAndLandscapeWithSyntheticHistory() async throws {
        let store = EventRunStore(directory: root.appendingPathComponent("runs"), authorized: { true }, blockingReason: { nil })
        let run = try store.startNewRun(context: EventRunContext(designID: nil, commercialEventID: nil, serverBinding: nil, name: "Synthetic Event"))
        try store.beginSession(id: "synthetic", runID: run.id, format: "solo")
        store.updateSession(id: "synthetic") { $0.completedAt = Date(); $0.printOutcomes["batch/1"] = "delivered" }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        for size in [CGSize(width: 834, height: 1194), CGSize(width: 1194, height: 834)] {
            let view = NavigationStack { EventRunReportingView(store: store, library: library(), archiveDirectory: root.appendingPathComponent("archive"), loadsRemote: false) }
            let host = UIHostingController(rootView: view)
            let window = UIWindow(windowScene: scene); window.frame = CGRect(origin: .zero, size: size)
            window.rootViewController = host; window.makeKeyAndVisible()
            try await Task.sleep(for: .milliseconds(400))
            host.view.frame = window.bounds; host.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(size: size).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
            XCTAssertGreaterThan(image.pngData()?.count ?? 0, 20_000)
            let name = size.width < size.height ? "event-run-report-portrait" : "event-run-report-landscape"
            let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
            try image.pngData()?.write(to: URL(fileURLWithPath: "/tmp/" + name + ".png"))
            window.isHidden = true
        }
    }
}
