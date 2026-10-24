import XCTest
@testable import PocketPixelsBooth

@MainActor final class V41RecoveryReader: CheckoutRecoveryReading {
    nonisolated let environment = "test"
    var response: CheckoutRecoveryResponse?
    var beforeReturn: (() -> Void)?
    var readCount = 0
    @MainActor func checkoutRecovery(checkoutSessionID: String) async throws -> CheckoutRecoveryResponse {
        readCount += 1
        beforeReturn?()
        guard let response else { throw PaymentsAPIError.unavailable }
        return response
    }
}

@MainActor final class OperatorWorkspaceV41ManagementTests: XCTestCase {
    private var root: URL!
    override func setUp() async throws { root = FileManager.default.temporaryDirectory.appendingPathComponent("v41-management-\(UUID())") }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }
    func checkpoint(_ id: String = "PP-20261025-120000", method: String? = nil, phase: CheckoutPhase = .orderRequested) -> CheckoutCheckpoint {
        .init(id: id, environment: "test", eventID: "ev", policyRevisionID: "r1", unitPriceCentavos: 5000,
            copies: 3, format: "solo", method: method, phase: phase, createdAt: Date(), updatedAt: Date())
    }
    func server(state: String? = nil, entitlement: String? = nil, id: String = "PP-20261025-120000") throws -> CheckoutRecoveryResponse {
        let ent = entitlement.map { #"{"id":"e1","orderId":"o1","eventId":"ev","policyRevisionId":"r1","sessionId":"\#(id)","selectedFormat":"solo","purchasedCopies":3,"unitPriceCentavos":5000,"totalCentavos":15000,"authorizationSource":"VERIFIED_QRPH","authorizedAt":"2026-10-25T03:00:00.000Z","state":"\#($0)"}"# } ?? "null"
        let order = state.map { #"{"order":{"id":"o1","eventId":"ev","policyRevisionId":"r1","format":"solo","copies":3,"unitPriceCentavos":5000,"totalCentavos":15000,"currency":"PHP","state":"PAYMENT_PENDING","paymentMethod":"QRPH"},"attempt":{"id":"a1","method":"QRPH","state":"\#($0)"},"entitlement":\#(ent),"printOutcomes":[]}"# } ?? ""
        let json = #"{"checkoutSessionId":"\#(id)","orders":[\#(order)],"openOrderId":\#(state == nil ? "null" : "\"o1\""),"serverTime":"2026-10-25T04:00:00.000Z"}"#
        return try PaymentsAPIClient.makeDecoder().decode(CheckoutRecoveryResponse.self, from: Data(json.utf8))
    }
    func testEmptyDeletionRevalidatesServerAndIsDurableIdempotent() async throws {
        let store = try CheckoutCheckpointStore(directory: root); let checkpoint = checkpoint(); try store.begin(checkpoint)
        let reader = V41RecoveryReader(); reader.response = try server()
        let coordinator = PaymentRecoveryCoordinator(checkpointStore: { store }, reader: { reader }, outboxClient: { nil }, managementAuthorized: { true }, inspectManagementDependencies: { _ in .init() })
        let preflight = await coordinator.checkoutDeletionDecision(id: checkpoint.id); XCTAssertEqual(preflight.category, .eligible)
        try await coordinator.deleteEligibleCheckout(id: checkpoint.id)
        XCTAssertEqual(reader.readCount, 2, "Deletion does not trust the preflight")
        XCTAssertNil(store.checkpoint(id: checkpoint.id))
        let relaunched = try CheckoutCheckpointStore(directory: root)
        XCTAssertNil(relaunched.checkpoint(id: checkpoint.id))
        XCTAssertFalse(relaunched.update(id: checkpoint.id) { $0.phase = .entitled }, "Late callback cannot recreate it")
        XCTAssertThrowsError(try relaunched.begin(checkpoint))
        try await coordinator.deleteEligibleCheckout(id: checkpoint.id)
    }
    func testPendingLatePaidUnknownAndUsableEntitlementCannotBeDeleted() throws {
        let checkpoint = checkpoint(method: "QRPH", phase: .awaitingProvider)
        for state in ["AWAITING_PAYMENT", "UNKNOWN_RECONCILIATION", "EXPIRED", "PAID_VERIFIED"] {
            let result = CheckoutDeletionPolicy.decide(checkpoint: checkpoint, server: try server(state: state), dependencies: .init())
            XCTAssertEqual(result.category, .archiveInstead, state)
        }
        for entitlement in ["AUTHORIZED", "IN_SESSION", "REVIEW_REQUIRED"] {
            XCTAssertEqual(CheckoutDeletionPolicy.decide(checkpoint: checkpoint, server: try server(state: "PAID_VERIFIED", entitlement: entitlement), dependencies: .init()).category, .archiveInstead)
        }
        XCTAssertEqual(CheckoutDeletionPolicy.decide(checkpoint: checkpoint, server: try server(state: "QR_EXPIRED_CONFIRMED"), dependencies: .init()).category, .eligible)
        XCTAssertEqual(CheckoutDeletionPolicy.decide(checkpoint: checkpoint, server: try server(state: "PAID_VERIFIED", entitlement: "CONSUMED"), dependencies: .init()).category, .eligible)
    }
    func testLatePaymentBetweenPreflightAndDeleteIsRechecked() async throws {
        let store = try CheckoutCheckpointStore(directory: root), cp = checkpoint(method: "QRPH", phase: .awaitingProvider); try store.begin(cp)
        let reader = V41RecoveryReader(); reader.response = try server(state: "QR_EXPIRED_CONFIRMED")
        let coordinator = PaymentRecoveryCoordinator(checkpointStore: { store }, reader: { reader }, outboxClient: { nil }, managementAuthorized: { true }, inspectManagementDependencies: { _ in .init() })
        let before = await coordinator.checkoutDeletionDecision(id: cp.id); XCTAssertEqual(before.category, .eligible)
        reader.response = try server(state: "PAID_VERIFIED", entitlement: "AUTHORIZED")
        do { try await coordinator.deleteEligibleCheckout(id: cp.id); XCTFail() } catch { }
        XCTAssertNotNil(store.checkpoint(id: cp.id))
    }
    func testConcurrentCheckpointChangeAndMissingServerRejectDeletion() async throws {
        let store = try CheckoutCheckpointStore(directory: root), cp = checkpoint(); try store.begin(cp)
        let reader = V41RecoveryReader(); reader.response = try server()
        let coordinator = PaymentRecoveryCoordinator(checkpointStore: { store }, reader: { reader }, outboxClient: { nil }, managementAuthorized: { true }, inspectManagementDependencies: { _ in .init() })
        reader.beforeReturn = { store.update(id: cp.id) { $0.phase = .paymentRequested; $0.method = "QRPH" } }
        let changed = await coordinator.checkoutDeletionDecision(id: cp.id); XCTAssertEqual(changed.category, .blocked)
        reader.beforeReturn = nil; reader.response = nil
        let offline = await coordinator.checkoutDeletionDecision(id: cp.id); XCTAssertEqual(offline.category, .cannotInspect)
        XCTAssertNotNil(store.checkpoint(id: cp.id))
    }
    func testArchiveRestoreKeepsParkedFinancialWarningsAndOriginalIdentity() async throws {
        let store = try CheckoutCheckpointStore(directory: root), cp = checkpoint(method: "QRPH", phase: .awaitingProvider); try store.begin(cp)
        let reader = V41RecoveryReader(); reader.response = try server(state: "UNKNOWN_RECONCILIATION")
        let coordinator = PaymentRecoveryCoordinator(checkpointStore: { store }, reader: { reader }, outboxClient: { nil }, managementAuthorized: { true }, inspectManagementDependencies: { _ in .init() })
        XCTAssertThrowsError(try coordinator.setCheckoutHidden(id: cp.id, hidden: true))
        XCTAssertTrue(store.park(id: cp.id, reason: "guest left")); await coordinator.refresh()
        try coordinator.setCheckoutHidden(id: cp.id, hidden: true)
        XCTAssertEqual(coordinator.activeInterruptionCount, 0); XCTAssertEqual(coordinator.parkedFollowUpCount, 1)
        XCTAssertNotNil(try CheckoutCheckpointStore(directory: root).checkpoint(id: cp.id)?.hiddenAt)
        XCTAssertFalse(store.checkpoint(id: cp.id)!.isResolved)
        try coordinator.setCheckoutHidden(id: cp.id, hidden: false)
        XCTAssertNil(store.checkpoint(id: cp.id)?.hiddenAt)
        XCTAssertEqual(store.checkpoint(id: cp.id)?.eventID, cp.eventID)
    }
    func testUnresolvedPhysicalCashAndIncompleteInspectionAreProtected() throws {
        let cp = checkpoint(method: "QRPH", phase: .awaitingProvider), response = try server(state: "QR_EXPIRED_CONFIRMED")
        XCTAssertEqual(CheckoutDeletionPolicy.decide(checkpoint: cp, server: response, dependencies: .init(receiptNeedsReview: true)).category, .blocked)
        XCTAssertEqual(CheckoutDeletionPolicy.decide(checkpoint: cp, server: response, dependencies: .init(inspectionComplete: false)).category, .cannotInspect)
        let cash = OfflineCashRecord(id: "cash", localSequence: 1, eventID: "ev", policyRevisionID: "r1", sessionID: cp.id, format: "solo", copies: 3,
            unitPriceCentavos: 5000, totalCentavos: 15000, declaredAt: Date(), syncState: .pending)
        XCTAssertEqual(CheckoutDeletionPolicy.decide(checkpoint: cp, server: response, dependencies: .init(cash: [cash])).category, .archiveInstead)
        let outbox = try PrintOutcomeOutbox(directory: root)
        try outbox.beginCopy(batchID: "batch", sessionID: cp.id, entitlementID: nil, receiptFingerprint: "fixture", copyIndex: 1, copyCount: 3, transport: "test")
        XCTAssertEqual(CheckoutDeletionPolicy.decide(checkpoint: cp, server: response, dependencies: .init(copies: outbox.entries)).category, .blocked)
        XCTAssertTrue(outbox.finishCopy(batchID: "batch", copyIndex: 1, state: .uncertain))
        let reopened = try PrintOutcomeOutbox(directory: root)
        XCTAssertEqual(CheckoutDeletionPolicy.decide(checkpoint: cp, server: response, dependencies: .init(copies: reopened.entries)).category, .blocked)
        try reopened.acknowledgeInspection(entryIDs: reopened.inspectionEntryIDs)
        XCTAssertEqual(CheckoutDeletionPolicy.decide(checkpoint: cp, server: response, dependencies: .init(copies: reopened.entries)).category, .eligible, "Acknowledged historical uncertainty is evidence, not a permanent lock")
    }
    func testFailedDeletionWriteRetainsCheckpointAndRetrySucceeds() throws {
        var fails = false
        let store = try CheckoutCheckpointStore(directory: root, writer: { data, url in
            if fails { throw CocoaError(.fileWriteOutOfSpace) }; try DurableFileWriter.write(data, to: url)
        })
        let cp = checkpoint(); try store.begin(cp); fails = true
        XCTAssertThrowsError(try store.deleteCheckpoint(id: cp.id)); XCTAssertNotNil(store.checkpoint(id: cp.id))
        XCTAssertNotNil(try CheckoutCheckpointStore(directory: root).checkpoint(id: cp.id))
        fails = false; try store.deleteCheckpoint(id: cp.id)
        XCTAssertNil(try CheckoutCheckpointStore(directory: root).checkpoint(id: cp.id))
    }
    func testMediaRemovalKeepsEventUseEvidence() throws {
        let store = try RecentSessionArchiveStore(directoryURL: root.appendingPathComponent("archive"))
        var payload = try V41ArchiveFixture.payload(); payload.eventDesignID = "used-design"; payload.eventRunID = "used-run"
        try SessionArchiveCommitter.commitPrintPayload(payload, store: store)
        XCTAssertEqual(try store.summaries().first?.eventDesignID, "used-design", "Print-critical commit preserves attribution")
        try store.delete(archiveID: payload.committedSession.galleryToken)
        XCTAssertTrue(try store.summaries().isEmpty)
        let evidence = try store.deletedSessionEvidence()
        XCTAssertEqual(evidence.map(\.eventRunID), ["used-run"]); XCTAssertEqual(evidence.map(\.eventDesignID), ["used-design"])
        XCTAssertEqual(evidence.map(\.sessionID), [payload.committedSession.sessionIdentifier])
    }
}

extension OperatorWorkspaceV41ManagementTests {
    func testCompletedPaidMediaCleanupRetainsFinancialAndPrintEvidence() async throws {
        let archive = try RecentSessionArchiveStore(directoryURL: root.appendingPathComponent("archive")), payload = try V41ArchiveFixture.payload()
        try archive.save(payload)
        let checkpoints = try CheckoutCheckpointStore(directory: root.appendingPathComponent("payments"))
        let cp = checkpoint(method: "QRPH", phase: .completed); try checkpoints.begin(cp); XCTAssertTrue(checkpoints.resolve(id: cp.id, reason: "completed"))
        let outbox = try PrintOutcomeOutbox(directory: root.appendingPathComponent("payments"))
        try outbox.beginCopy(batchID: "paid-batch", sessionID: cp.id, entitlementID: "paid-entitlement", receiptFingerprint: "fixture", copyIndex: 1, copyCount: 1, transport: "test")
        XCTAssertTrue(outbox.finishCopy(batchID: "paid-batch", copyIndex: 1, state: .delivered))
        let recovery = try AppRecoveryStore(directoryURL: root.appendingPathComponent("recovery")), pending = try GalleryPendingUploadStore(directoryURL: root.appendingPathComponent("queue"))
        let summary = try XCTUnwrap(archive.summaries().first)
        let inspect: @MainActor (RecentSessionArchiveSummary) throws -> RecordCleanupDecision = {
            try SessionMediaOperations.sessionDeletionDecision($0, checkpoints: checkpoints, outbox: outbox, recoveryStore: recovery, pendingStore: pending)
        }
        XCTAssertEqual(try inspect(summary).category, .eligible)
        let model = RecentSessionsViewModel(store: archive, managementAuthorized: { true }, mediaDeletionInspector: inspect)
        let results = await model.deleteSelected([summary])
        XCTAssertEqual(results[summary.archiveID], "Deleted local media.")
        XCTAssertTrue(try archive.summaries().isEmpty)
        XCTAssertEqual(checkpoints.checkpoint(id: cp.id)?.resolution, "completed")
        XCTAssertEqual(outbox.entries.count, 1); XCTAssertEqual(outbox.entries[0].entitlementID, "paid-entitlement")
    }
    func testPendingUploadIndependentCopiesPermitMediaCleanupAndKeepQueue() throws {
        let archive = try RecentSessionArchiveStore(directoryURL: root.appendingPathComponent("archive")), payload = try V41ArchiveFixture.payload()
        try archive.save(payload)
        let pending = try GalleryPendingUploadStore(directoryURL: root.appendingPathComponent("queue"))
        let prepared = try GoogleDriveGalleryUploadService.preparePayload(photos: payload.committedSession.photos, composedReceipt: payload.committedSession.photos[0],
            sessionID: payload.committedSession.sessionIdentifier, createdAt: Date(), galleryToken: payload.committedSession.galleryToken, customerGalleryBaseURL: URL(string: "https://synthetic.example.test")!)
        try pending.save(prepared)
        let checkpoints = try CheckoutCheckpointStore(directory: root.appendingPathComponent("payments")), outbox = try PrintOutcomeOutbox(directory: root.appendingPathComponent("payments"))
        let recovery = try AppRecoveryStore(directoryURL: root.appendingPathComponent("recovery")), summary = try XCTUnwrap(archive.summaries().first)
        XCTAssertEqual(try SessionMediaOperations.sessionDeletionDecision(summary, checkpoints: checkpoints, outbox: outbox, recoveryStore: recovery, pendingStore: pending).category, .eligible)
        try archive.delete(archiveID: summary.archiveID)
        XCTAssertEqual(try pending.load(galleryToken: summary.archiveID)?.photos.map(\.data), prepared.photos.map(\.data))
    }
    func testCurrentRecoveryAndConcurrentReprintRejectCleanupUntilAcknowledgementRelaunch() throws {
        let archive = try RecentSessionArchiveStore(directoryURL: root.appendingPathComponent("archive")), payload = try V41ArchiveFixture.payload()
        try archive.save(payload)
        let summary = try XCTUnwrap(archive.summaries().first), checkpoints = try CheckoutCheckpointStore(directory: root.appendingPathComponent("payments"))
        let outbox = try PrintOutcomeOutbox(directory: root.appendingPathComponent("payments")), pending = try GalleryPendingUploadStore(directoryURL: root.appendingPathComponent("queue"))
        let recoveryRoot = root.appendingPathComponent("recovery"), recovery = try AppRecoveryStore(directoryURL: recoveryRoot)
        let snapshot = AppRecoverySnapshot(schemaVersion: 1, sessionIdentifier: summary.sessionIdentifier, createdAt: Date(), format: .solo, eventProfile: nil,
            galleryToken: summary.archiveID, galleryURL: payload.committedSession.galleryURL, photoJPEGData: payload.photoThumbnailData,
            receiptPreviewPNGData: payload.receiptPreviewPNGData, thermalPreviewPNGData: payload.thermalPreviewPNGData, rasterFingerprint: summary.rasterFingerprint,
            stage: .printStatusUnknown, updatedAt: Date(), checkpointID: "synthetic-checkpoint")
        try recovery.saveCritical(snapshot)
        func decision(_ store: AppRecoveryStore) throws -> RecordCleanupDecision {
            try SessionMediaOperations.sessionDeletionDecision(summary, checkpoints: checkpoints, outbox: outbox, recoveryStore: store, pendingStore: pending)
        }
        XCTAssertEqual(try decision(recovery).category, .blocked)
        _ = try OperatorRecoveryAcknowledgement.retainAndAcknowledge(snapshot, store: recovery)
        let relaunched = try AppRecoveryStore(directoryURL: recoveryRoot)
        XCTAssertEqual(try decision(relaunched).category, .eligible)
        XCTAssertTrue(SessionSetupSafety.decision(for: .startUnrelatedGuest, activeGuest: false, printerWorking: false, needsReceiptCheck: false,
            hasPendingSession: false, checkpoints: checkpoints, outbox: outbox).allowed)
        SessionMediaOperations.reprinting.insert(summary.sessionIdentifier)
        defer { SessionMediaOperations.reprinting.remove(summary.sessionIdentifier) }
        XCTAssertEqual(try decision(relaunched).category, .blocked)
    }
    func testBulkSessionDeletionReportsPartialResultsAndRevalidatesEachItem() async throws {
        let archive = try RecentSessionArchiveStore(directoryURL: root.appendingPathComponent("archive"))
        let first = try V41ArchiveFixture.payload(), second = try V41ArchiveFixture.payload(token: String(repeating: "b", count: 64), sessionID: "PP-other")
        try archive.save(first); try archive.save(second)
        let summaries = try archive.summaries()
        var inspections = 0
        let model = RecentSessionsViewModel(store: archive, managementAuthorized: { true }, mediaDeletionInspector: { summary in
            inspections += 1
            return summary.archiveID == first.committedSession.galleryToken ? .eligible : .init(category: .blocked, reason: "A guest is using this session.")
        })
        let results = await model.deleteSelected(summaries)
        XCTAssertEqual(inspections, 2)
        XCTAssertEqual(results[first.committedSession.galleryToken], "Deleted local media.")
        XCTAssertEqual(results[second.committedSession.galleryToken], "A guest is using this session.")
        XCTAssertEqual(try archive.summaries().map(\.archiveID), [second.committedSession.galleryToken])
    }
}
