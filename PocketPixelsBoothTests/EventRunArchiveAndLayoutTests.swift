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
        try library.archiveDesign(id: design.id)
        XCTAssertNotNil(library.design(id: design.id)?.archivedAt, "Archiving unrelated configuration cannot interrupt the guest")
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

extension EventRunArchiveAndLayoutTests {
    func testUnusedDeletionIgnoresLaterUnassignedRegularSessionsIncludingRemovedMedia() throws {
        let library = library()
        var design = try library.create(name: "Unused", venue: "")
        design.createdAt = Date().addingTimeInterval(-3600); try library.save(design)
        let archive = try RecentSessionArchiveStore(directoryURL: root.appendingPathComponent("regular"))
        var regular = try payload(); regular.eventDesignID = nil; regular.eventRunID = nil
        try archive.save(regular)
        let summaries = try archive.summaries()
        XCTAssertGreaterThan(summaries[0].createdAt, design.createdAt)
        // Reload the durable configuration before inspecting and deleting it.
        let saved = self.library()
        XCTAssertNil(saved.deletionIneligibility(id: design.id, runs: [], archives: summaries, historyAvailable: true))
        try archive.delete(archiveID: summaries[0].archiveID)
        try saved.deleteUnusedDesign(id: design.id, runs: [], archives: summaries, historyAvailable: true, deletedSessions: archive.deletedSessionEvidence())
        XCTAssertNil(self.library().design(id: design.id))
        XCTAssertEqual(library.library.events.count, 1, "The original in-memory store is independent of the relaunched store")
    }

    func testRemovingHistoricalConfigurationKeepsExactIdentityCommercialOwnershipAndArchivesAcrossRelaunch() throws {
        let library = library()
        let used = try library.create(name: "Original Celebration", venue: ""), other = try library.create(name: "Keep Me", venue: "")
        try library.link(designID: used.id, binding: "test:synthetic", serverEventID: "server-original")
        let run = EventRunRecord(id: "run-original", context: .init(designID: used.id, commercialEventID: "server-original", serverBinding: "test:synthetic", name: "Original Celebration"), createdAt: Date(), status: .completed)
        let archive = try RecentSessionArchiveStore(directoryURL: root.appendingPathComponent("archive"))
        var media = try payload(); media.eventDesignID = used.id; media.eventRunID = run.id
        try archive.save(media)
        let before = try archive.reportingSummaries()
        try library.removeSavedDesign(id: used.id, runs: [run], historyAvailable: true)
        let relaunched = self.library()
        XCTAssertNil(relaunched.design(id: used.id)); XCTAssertNotNil(relaunched.design(id: other.id))
        XCTAssertEqual(relaunched.library.historicalName(id: used.id), "Original Celebration")
        XCTAssertTrue(relaunched.library.knownServerEventIDs(binding: "test:synthetic").contains("server-original"))
        XCTAssertEqual(try archive.reportingSummaries(), before)
        XCTAssertEqual(run.context.designID, used.id)
        XCTAssertThrowsError(try relaunched.save(used), "A late setup save cannot resurrect a removed identity")
        XCTAssertThrowsError(try relaunched.adopt(serverEventID: "server-original", name: "Reassigned", venue: "", binding: "test:synthetic"))
        XCTAssertThrowsError(try relaunched.link(designID: other.id, binding: "test:synthetic", serverEventID: "server-original"))
        XCTAssertThrowsError(try relaunched.setRegularServerEvent("server-original", binding: "test:synthetic"))
        try relaunched.removeSavedDesign(id: used.id, runs: [run], historyAvailable: true)
        XCTAssertEqual(relaunched.library.removedDesigns?.count, 1)
    }

    func testRemovalProtectsActiveAppliedPendingAndUnauthorizedOperations() throws {
        var authorized = true, busy: String?
        let library = library(authorized: { authorized }, blocked: { busy })
        let design = try library.create(name: "Protected", venue: "")
        var run = EventRunRecord(id: "running", context: .init(designID: design.id, commercialEventID: nil, serverBinding: nil, name: "Protected"), createdAt: Date(), status: .active)
        XCTAssertThrowsError(try library.removeSavedDesign(id: design.id, runs: [run], historyAvailable: true))
        run.status = .completed
        try library.recordApplied(eventModeEnabled: true, eventID: design.id)
        XCTAssertThrowsError(try library.removeSavedDesign(id: design.id, runs: [run], historyAvailable: true))
        try library.recordApplied(eventModeEnabled: false, eventID: nil)
        busy = "Finish the unrelated active guest first."
        let unrelated = try library.create(name: "Unrelated unused design", venue: "")
        try library.removeSavedDesign(id: unrelated.id, runs: [run], historyAvailable: true)
        XCTAssertNil(library.design(id: unrelated.id), "Retiring unrelated configuration does not change a guest's frozen setup")
        busy = nil; authorized = false
        XCTAssertThrowsError(try library.removeSavedDesign(id: design.id, runs: [run], historyAvailable: true))
        authorized = true
        XCTAssertThrowsError(try library.removeSavedDesign(id: design.id, runs: [run], historyAvailable: true, pendingCreation: true))
        XCTAssertThrowsError(try library.removeSavedDesign(id: design.id, runs: [run], historyAvailable: false))
        XCTAssertNotNil(library.design(id: design.id))
        try library.removeSavedDesign(id: design.id, runs: [run], historyAvailable: true)
        XCTAssertNil(self.library().design(id: design.id))
    }

    func testFailedRemovalWriteRetainsDesignAndRetryPersistsReferenceAtomically() throws {
        var fails = false
        let library = EventDesignLibraryStore(directory: root.appendingPathComponent("designs"), write: { data, url in
            if fails { throw CocoaError(.fileWriteOutOfSpace) }; try DurableFileWriter.write(data, to: url)
        }, legacyProfile: { .pocketPixelsDefault }, legacyName: { "" }, operationAuthorized: { true }, operationBlockingReason: { nil })
        let design = try library.create(name: "Durable", venue: "")
        fails = true
        XCTAssertThrowsError(try library.removeSavedDesign(id: design.id, runs: [], historyAvailable: true))
        XCTAssertNotNil(library.design(id: design.id)); XCTAssertNotNil(self.library().design(id: design.id))
        XCTAssertTrue(library.library.removedDesigns?.isEmpty ?? true)
        fails = false
        try library.removeSavedDesign(id: design.id, runs: [], historyAvailable: true)
        XCTAssertNil(self.library().design(id: design.id))
        XCTAssertEqual(self.library().library.removedDesigns?.first?.id, design.id)
    }

    func testUnusedRunIgnoresUnassignedSessionsButRetainsExactEvidenceAndRestoreIsHistorical() throws {
        let runs = EventRunStore(directory: root.appendingPathComponent("runs"), authorized: { true }, blockingReason: { nil })
        let run = try runs.createHistoricalRun(name: "Earlier occurrence", designID: nil, startedAt: Date().addingTimeInterval(-3600), endedAt: Date())
        let archive = try RecentSessionArchiveStore(directoryURL: root.appendingPathComponent("archive"))
        var media = try payload(); media.eventRunID = nil; media.eventDesignID = nil
        try archive.save(media)
        XCTAssertNil(runs.unusedRunDeletionReason(id: run.id, archives: try archive.summaries(), inspectionComplete: true))
        try runs.transition(id: run.id, to: .archived)
        try runs.restoreArchivedRun(id: run.id)
        XCTAssertEqual(runs.runs.first?.status, .completed); XCTAssertNil(runs.currentRunID)
        try archive.delete(archiveID: media.committedSession.galleryToken)
        try runs.deleteUnusedRun(id: run.id, archives: [], inspectionComplete: true, deletedSessions: archive.deletedSessionEvidence())
        XCTAssertTrue(EventRunStore(directory: runs.directory).runs.isEmpty)
    }
}

extension EventRunArchiveAndLayoutTests {
    func testExplicitLegacyAttributionProtectsOnlyItsRunEvenAfterMediaRemoval() throws {
        let runs = EventRunStore(directory: root.appendingPathComponent("runs"), authorized: { true }, blockingReason: { nil })
        let used = try runs.createHistoricalRun(name: "Operator-attributed event", designID: nil, startedAt: Date().addingTimeInterval(-7200), endedAt: Date())
        let unused = try runs.createHistoricalRun(name: "Unrelated event", designID: nil, startedAt: Date().addingTimeInterval(-7200), endedAt: Date())
        let archive = try RecentSessionArchiveStore(directoryURL: root.appendingPathComponent("archive"))
        var media = try payload(); media.eventRunID = nil; media.eventDesignID = nil
        try archive.save(media)
        let summary = try XCTUnwrap(archive.summaries().first)
        let attribution = LegacyAttributionStore(directory: runs.directory, authorized: { true })
        try attribution.attribute(summary, to: used, note: "Synthetic operator attribution", exact: [])
        try archive.delete(archiveID: summary.archiveID)
        let deleted = try archive.deletedSessionEvidence()
        XCTAssertTrue(runs.unusedRunDeletionReason(id: used.id, archives: [], inspectionComplete: true)?.contains("explicitly attributed") == true)
        XCTAssertThrowsError(try runs.deleteUnusedRun(id: used.id, archives: [], inspectionComplete: true, deletedSessions: deleted))
        try runs.deleteUnusedRun(id: unused.id, archives: [], inspectionComplete: true, deletedSessions: deleted)
        XCTAssertEqual(runs.runs.map(\.id), [used.id])
        XCTAssertEqual(LegacyAttributionStore(directory: runs.directory).attributions, attribution.attributions)
    }
}
