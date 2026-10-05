import XCTest
import UIKit
@testable import PocketPixelsBooth

@MainActor
final class EventOperationsTests: XCTestCase {
    private func report(_ checks: [EventReadinessCheck]) -> EventReadinessReport {
        EventReadinessReport(checks: checks, generatedAt: Date())
    }
    private func check(_ severity: EventReadinessCheck.Severity, _ status: EventReadinessCheck.Status, _ title: String = "Check") -> EventReadinessCheck {
        EventReadinessCheck(severity: severity, title: title, status: status, detail: title)
    }
    func testNoChecksCannotClaimReady() {
        XCTAssertEqual(report([]).readiness, .notReady)
        XCTAssertFalse(report([]).isReadyForEvent)
    }
    func testAllPassingChecksAreReady() {
        XCTAssertEqual(report([check(.critical, .pass), check(.important, .pass)]).readiness, .ready)
    }
    func testOfflinePendingUploadsNeedAttentionButDoNotBlockPrinting() {
        let value = report([check(.critical, .pass, "Printer"), check(.important, .warning, "Internet"), check(.important, .warning, "Pending uploads")])
        XCTAssertEqual(value.readiness, .attention)
        XCTAssertTrue(value.isReadyForEvent)
        XCTAssertEqual(value.reasons.count, 2)
    }
    func testPrinterRecoveryLockBlocksReadiness() {
        XCTAssertEqual(report([check(.critical, .fail, "Printer Recovery"), check(.important, .warning)]).readiness, .notReady)
    }
    func testUnverifiedCriticalCameraCannotClaimReady() {
        XCTAssertEqual(report([check(.critical, .warning, "Camera")]).readiness, .notReady)
    }
    func testOptionalProfileAttentionDoesNotBlockOperation() {
        XCTAssertEqual(report([check(.critical, .pass), check(.optional, .warning)]).readiness, .attention)
    }
    func testStorageThresholdBoundaries() {
        XCTAssertEqual(StorageHealth(bytes: -1), .critical)
        XCTAssertEqual(StorageHealth(bytes: 99_999_999).checkStatus, .fail)
        XCTAssertEqual(StorageHealth(bytes: 100_000_000), .low)
        XCTAssertEqual(StorageHealth(bytes: 499_999_999).checkStatus, .warning)
        XCTAssertEqual(StorageHealth(bytes: 500_000_000), .healthy)
        XCTAssertEqual(StorageHealth(bytes: 1_000_000_000).checkStatus, .pass)
    }
    func testReprintRequiresIdleUnlockedResolvedState() {
        for busy in [false, true] {
            for locked in [false, true] {
                for unresolved in [false, true] {
                    XCTAssertEqual(OperatorPrintPolicy.canReprint(busy: busy, recoveryLocked: locked, unresolvedPrint: unresolved), !busy && !locked && !unresolved)
                }
            }
        }
    }
    func testUnknownPrintNeedsFreshAcknowledgementAfterRelaunch() {
        XCTAssertTrue(OperatorPrintPolicy.requiresAcknowledgement(stage: .printStatusUnknown, snapshotIdentity: "session-1", acknowledgedIdentity: nil))
        XCTAssertFalse(OperatorPrintPolicy.requiresAcknowledgement(stage: .printStatusUnknown, snapshotIdentity: "session-1", acknowledgedIdentity: "session-1"))
        XCTAssertTrue(OperatorPrintPolicy.requiresAcknowledgement(stage: .printStatusUnknown, snapshotIdentity: "session-2", acknowledgedIdentity: "session-1"))
        XCTAssertFalse(OperatorPrintPolicy.requiresAcknowledgement(stage: .receiptComposed, snapshotIdentity: "session-1", acknowledgedIdentity: nil))
    }

    func testRequestedCopiesCountBatchesOnceIncludingFailedBatch() {
        let batch = UUID()
        let records = [audit(batch: batch, copies: 5), audit(batch: batch, copies: 5), audit(batch: UUID(), copies: 2, result: .failedBeforeBytes)]
        XCTAssertEqual(OperatorAuditSummary(records: records).requestedCopies, 7)
    }
    func testRecoveryEventsCountUniqueUnknownJobsOnly() {
        let unknown = audit(batch: UUID(), copies: 3, result: .recoveryRequiredAfterBytes)
        let records = [unknown, unknown, audit(batch: UUID(), copies: 1), audit(batch: UUID(), copies: 1, result: .failedBeforeBytes)]
        XCTAssertEqual(OperatorAuditSummary(records: records).recoveryEvents, 1)
    }
    func testRapidStartCannotReplaceAnExistingSession() {
        let model = BoothSessionViewModel()
        model.state = .choosingFormat
        model.sessionIdentifier = "existing"
        model.selectedPrintCopies = 3
        model.startSession()
        XCTAssertEqual(model.sessionIdentifier, "existing")
        XCTAssertEqual(model.selectedPrintCopies, 3)
        XCTAssertEqual(model.state, .choosingFormat)
    }
    func testNextCustomerResetClearsIdentityAndCopyCount() {
        let model = BoothSessionViewModel()
        model.sessionIdentifier = "previous"
        model.galleryToken = "previous-token"
        model.selectedPrintCopies = 5
        model.state = .thankYou
        model.resetAfterDone()
        XCTAssertNil(model.sessionIdentifier)
        XCTAssertNil(model.galleryToken)
        XCTAssertEqual(model.selectedPrintCopies, 1)
        XCTAssertEqual(model.state, .welcome)
    }
    func testStorageProbeLeavesExistingDataIntact() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = Data("customer data".utf8)
        let file = directory.appendingPathComponent("customer")
        try data.write(to: file)
        try OperatorStorageProbe.verify(directory: directory)
        XCTAssertEqual(try Data(contentsOf: file), data)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["customer"])
    }
    func testStorageProbeFailureIsNotReportedAsAccessible() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("missing")
        XCTAssertThrowsError(try OperatorStorageProbe.verify(directory: missing))
    }
    func testOldArchivesSurviveSaveAndStoreReopen() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try RecentSessionArchiveStore(directoryURL: directory)
        let raster = try ReliabilityFixtures.rasterizedImage(seed: 91)
        let image = ReliabilityFixtures.syntheticPhoto(session: 91, photo: 1, format: .solo)
        let imageData = try XCTUnwrap(image.pngData())
        let date = Date(timeIntervalSince1970: 1_000)
        let token = String(repeating: "a", count: 64)
        var archivedProfile = EventProfile(
            isEnabled: true,
            eventName: "ARCHIVED WEDDING",
            subtitle: "",
            includeEventDate: false,
            eventDate: date,
            shortMessage: "",
            showEventTextBlock: false
        )
        archivedProfile.receiptHeader.mode = .customEventHeader
        archivedProfile.receiptHeader.assetIdentifier = UUID().uuidString.lowercased()
        let committed = CommittedGallerySession(sessionIdentifier: "old-session", createdAt: date, galleryToken: token, galleryURL: URL(string: "https://example.com/g/\(token)")!, photos: [image], format: .solo, eventProfile: archivedProfile)
        let receipt = ComposedReceipt(imagePNGData: imageData, width: raster.width, height: raster.height, previewContentHeight: raster.height, sessionIdentifier: "old-session", createdAt: date, format: .solo, photoQualityProfile: .customerPrintDefault)
        try store.save(RecentSessionArchivePayload(committedSession: committed, composedReceipt: receipt, receiptPreviewPNGData: imageData, thermalPreviewPNGData: imageData, rasterizedImage: raster, photoThumbnailData: [imageData]))
        let activeStaging = directory.appendingPathComponent("staging-active-customer")
        try FileManager.default.createDirectory(at: activeStaging, withIntermediateDirectories: true)
        let stagedPhoto = activeStaging.appendingPathComponent("photo.png")
        try imageData.write(to: stagedPhoto)
        let reopened = try RecentSessionArchiveStore(directoryURL: directory)
        XCTAssertEqual(try Data(contentsOf: stagedPhoto), imageData, "Opening the operator archive must not remove another save's in-flight files")
        XCTAssertEqual(try reopened.summaries().count, 1)
        let loaded = try reopened.load(archiveID: token)
        XCTAssertEqual(loaded.rasterizedImage.rasterData, raster.rasterData)
        XCTAssertEqual(loaded.eventProfile?.receiptHeader.assetIdentifier, archivedProfile.receiptHeader.assetIdentifier)
        XCTAssertEqual(RecentSessionArchiveStore.rasterFingerprint(for: loaded.rasterizedImage), RecentSessionArchiveStore.rasterFingerprint(for: raster))
    }
    private func audit(batch: UUID, copies: Int, result: PrintAuditRecord.TerminalResult = .completed) -> PrintAuditRecord {
        PrintAuditRecord(id: UUID(), timestamp: Date(), jobID: UUID(), batchID: batch,
            sessionIdentifier: "test-session", source: .liveCustomer, copyIndex: 1, copyCount: copies,
            payloadFingerprint: "1234567890abcdef", payloadByteCount: 100, imageWidth: 576, imageHeight: 64,
            rasterByteCount: 4608, transport: .bluetooth, bluetoothMode: nil, chunkSize: nil, chunkCount: nil,
            startedAt: Date(), transportFinishedAt: nil, physicalOwnershipReleasedAt: Date(), transportDuration: nil,
            handoffDuration: 0, flowControlPauseCount: nil, writeTimeout: nil,
            bytesStarted: result == .completed || result == .recoveryRequiredAfterBytes,
            terminalResult: result, recoveryReason: nil)
    }
}
