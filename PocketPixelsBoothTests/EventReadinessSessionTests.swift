import XCTest
import UIKit
@testable import PocketPixelsBooth

@MainActor final class EventReadinessSessionTests: XCTestCase {
    func testScopesUseOccurrenceIdentityAndKeepLegacyUnknownsInAllHistory() async throws {
        let values = [summary("current", run: "run-a"), summary("same-name-other-occurrence", run: "run-b"),
            summary("old-regular", regular: true), summary("legacy-event"), summary("unknown")]
        let model = RecentSessionsViewModel(summaryLoader: { values })
        model.refresh()
        let deadline = Date().addingTimeInterval(5)
        while !model.hasLoaded && Date() < deadline { await Task.yield() }
        XCTAssertTrue(model.hasLoaded)
        let run = EventRunRecord(id: "run-a", context: .init(designID: "design", commercialEventID: nil, serverBinding: nil, name: "CIM INTRAMS"), createdAt: Date(), status: .active)
        model.configureContext(run: run, eventApplied: true)
        XCTAssertEqual(model.scope, .currentEvent)
        XCTAssertEqual(model.currentEventName, "CIM INTRAMS")
        XCTAssertEqual(model.filteredSummaries.map(\.archiveID), ["current"])
        model.selectedArchiveID = "current"
        model.scope = .regularBooth
        XCTAssertNil(model.selectedArchiveID)
        XCTAssertEqual(model.filteredSummaries.map(\.archiveID), ["old-regular"])
        model.configureContext(run: run, eventApplied: true)
        XCTAssertEqual(model.scope, .regularBooth, "Keep the operator’s explicit choice in the same occurrence")
        model.scope = .allHistory
        XCTAssertEqual(model.filteredSummaries.count, values.count)
        model.searchText = "same-name"
        XCTAssertEqual(model.filteredSummaries.map(\.archiveID), ["same-name-other-occurrence"])
        model.clearFilters()
        model.configureContext(run: nil, eventApplied: false)
        XCTAssertEqual(model.scope, .regularBooth)
        XCTAssertEqual(model.summaries, values, "Scope changes do not mutate or reload archive media")
        model.configureContext(run: nil, eventApplied: true)
        XCTAssertTrue(model.filteredSummaries.isEmpty, "Never infer missing event-run membership")
    }

    func testCustomizedRegularBoothAssociationSurvivesArchiveReload() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("event-scope-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try RecentSessionArchiveStore(directoryURL: root)
        let fixture = try V41ArchiveFixture.payload()
        let original = fixture.committedSession
        var profile = EventProfile.pocketPixelsDefault
        profile.receiptExtrasEnabled = true
        profile.receiptDesign.editorialCaption = "Custom Regular Booth Caption"
        let session = CommittedGallerySession(sessionIdentifier: original.sessionIdentifier, createdAt: original.createdAt,
            galleryToken: original.galleryToken, galleryURL: original.galleryURL, photos: original.photos, format: original.format, eventProfile: profile)
        let receipt = try ReceiptComposer.compose(photos: session.photos, sessionIdentifier: session.sessionIdentifier,
            date: session.createdAt, galleryURL: session.galleryURL, format: session.format, eventProfile: profile)
        let raster = try ThermalImageRasterizer.rasterize(XCTUnwrap(UIImage(data: receipt.imagePNGData)), purpose: .completeReceipt)
        let payload = RecentSessionArchivePayload(committedSession: session, composedReceipt: receipt,
            receiptPreviewPNGData: receipt.imagePNGData, thermalPreviewPNGData: raster.previewPNGData,
            rasterizedImage: raster, photoThumbnailData: [], isRegularBooth: true)
        try store.save(payload)
        let reloaded = try RecentSessionArchiveStore(directoryURL: root)
        let summary = try XCTUnwrap(reloaded.summaries().first)
        XCTAssertTrue(summary.isKnownRegularBooth)
        XCTAssertTrue(RecentSessionScope.regularBooth.includes(summary, runID: nil))
        XCTAssertTrue(try reloaded.load(archiveID: summary.archiveID).summary.isKnownRegularBooth)
    }

    private func summary(_ id: String, run: String? = nil, regular: Bool = false) -> RecentSessionArchiveSummary {
        .init(archiveID: id, sessionIdentifier: id, createdAt: Date(timeIntervalSince1970: 1), format: .solo,
              eventName: regular ? nil : "CIM INTRAMS", eventLocation: nil, photoCount: 1,
              receiptWidth: 576, receiptHeight: 1000, estimatedLengthMillimeters: 125,
              rasterFingerprint: "fixture", thumbnailFilenames: [], lastReprintedAt: nil, reprintCount: 0,
              payloadSizeBytes: 0, eventRunID: run, isKnownRegularBooth: regular)
    }
}
