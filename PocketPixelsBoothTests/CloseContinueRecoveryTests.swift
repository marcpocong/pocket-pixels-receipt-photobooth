import XCTest
@testable import PocketPixelsBooth

@MainActor private final class ResolutionDisk {
    var fails = false
    func write(_ data: Data, _ url: URL) throws {
        if fails { throw CocoaError(.fileWriteOutOfSpace) }
        try DurableFileWriter.write(data, to: url)
    }
}

@MainActor final class CloseContinueRecoveryTests: XCTestCase {
    private var root: URL!
    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("close-continue-\(UUID())")
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }
    private func checkpoint(_ id: String = "original", method: String = "QRPH", phase: CheckoutPhase = .awaitingProvider) -> CheckoutCheckpoint {
        .init(id: id, environment: "test", deviceID: "device", accountID: "account", eventID: "original-event", policyRevisionID: "original-policy",
              unitPriceCentavos: 5000, copies: 3, format: "solo", method: method, orderID: "original-order", entitlementID: phase >= .entitled ? "original-entitlement" : nil,
              phase: phase, lastServerState: "UNKNOWN_RECONCILIATION", createdAt: Date(), updatedAt: Date())
    }
    private func snapshot(_ id: String = "original", stage: AppRecoveryStage = .photosCaptured) -> AppRecoverySnapshot {
        .init(schemaVersion: 1, sessionIdentifier: id, createdAt: Date(), format: .solo, eventProfile: .pocketPixelsDefault,
              galleryToken: String(repeating: "a", count: 64), galleryURL: URL(string: "https://example.test/original"),
              photoJPEGData: [Data([1, 2, 3])], receiptPreviewPNGData: Data([4, 5]), thermalPreviewPNGData: Data([6, 7]),
              rasterFingerprint: "original-raster", stage: stage, updatedAt: Date(), checkpointID: UUID().uuidString)
    }
    private func begin(_ outbox: PrintOutcomeOutbox, batch: String = "original-batch", copy: Int = 1) throws {
        try outbox.beginCopy(batchID: batch, sessionID: "original", entitlementID: "entitlement", receiptFingerprint: "original-raster", copyIndex: copy, copyCount: 3, transport: "bluetooth")
    }

    func testFailedResolutionStaysVisibleAndRetryCommitsBeforeRemoving() async throws {
        let disk = ResolutionDisk()
        let store = try CheckoutCheckpointStore(directory: root, writer: disk.write)
        try store.begin(checkpoint())
        let coordinator = PaymentRecoveryCoordinator(checkpointStore: { store }, reader: { nil }, outboxClient: { nil })
        await coordinator.refresh()
        let item = try XCTUnwrap(coordinator.items.first)
        disk.fails = true
        XCTAssertFalse(coordinator.dismiss(item, reason: "guest left"))
        XCTAssertEqual(coordinator.activeItems.count, 1)
        XCTAssertNotNil(coordinator.resolutionFailures[item.id])
        XCTAssertFalse(store.checkpoint(id: item.id)!.isParked)
        XCTAssertFalse(try CheckoutCheckpointStore(directory: root).checkpoint(id: item.id)!.isParked)
        disk.fails = false
        XCTAssertTrue(coordinator.dismiss(item, reason: "guest left"))
        XCTAssertTrue(coordinator.activeItems.isEmpty)
        XCTAssertEqual(coordinator.outstandingItems.count, 1)
        XCTAssertNil(coordinator.resolutionFailures[item.id])
        let restarted = try CheckoutCheckpointStore(directory: root)
        XCTAssertTrue(restarted.checkpoint(id: item.id)!.isParked)
        XCTAssertFalse(restarted.checkpoint(id: item.id)!.isResolved)
    }

    func testResolveReturnsFailureAndRepeatedSuccessKeepsFirstReasonAndTimestamp() throws {
        let disk = ResolutionDisk(), store = try CheckoutCheckpointStore(directory: root, writer: disk.write)
        try store.begin(checkpoint())
        disk.fails = true
        XCTAssertFalse(store.resolve(id: "original", reason: "server unpaid"))
        XCTAssertNil(store.checkpoint(id: "original")?.resolvedAt)
        disk.fails = false
        XCTAssertTrue(store.resolve(id: "original", reason: "server unpaid"))
        let first = store.checkpoint(id: "original")
        XCTAssertTrue(store.resolve(id: "original", reason: "second tap", now: Date().addingTimeInterval(50)))
        XCTAssertEqual(store.checkpoint(id: "original"), first)
    }

    func testConcurrentCloseIsIdempotentAndKeepsFinancialState() async throws {
        let store = try CheckoutCheckpointStore(directory: root)
        try store.begin(checkpoint(phase: .claimed))
        let item = CheckoutRecoveryItem(checkpoint: store.unresolved[0], classification: .claimedNotPrinted(verified: true))
        let coordinator = PaymentRecoveryCoordinator(checkpointStore: { store }, reader: { nil }, outboxClient: { nil })
        let tasks = (0..<8).map { _ in Task { coordinator.dismiss(item, reason: "guest left") } }
        for task in tasks { let success = await task.value; XCTAssertTrue(success) }
        let parked = try XCTUnwrap(store.checkpoint(id: "original"))
        XCTAssertNil(parked.resolution)
        XCTAssertEqual(parked.entitlementID, "original-entitlement")
        XCTAssertEqual(parked.copies, 3)
        XCTAssertEqual(parked.localClosureHistory?.count, 1)
        XCTAssertEqual(coordinator.outstandingItems.count, 1)
        XCTAssertTrue(coordinator.activeItems.isEmpty)
    }

    func testOperatorCloseRetainsPhotosPreviewsAndOriginalGalleryAcrossRelaunch() throws {
        let checkpoints = try CheckoutCheckpointStore(directory: root)
        try checkpoints.begin(checkpoint(phase: .claimed))
        let recovery = try AppRecoveryStore(directoryURL: root.appendingPathComponent("recovery"))
        let detached = DetachedCheckoutStore(directory: root.appendingPathComponent("detached"))
        let original = snapshot()
        try recovery.saveCritical(original)
        for _ in 0..<2 {
            try CheckoutInteractionClosure.close(id: "original", reason: "guest abandoned", checkpoints: checkpoints, recovery: recovery, detached: detached, snapshot: original)
        }
        let retained = try XCTUnwrap(detached.load(sessionID: "original"))
        XCTAssertEqual(retained.snapshot.photoJPEGData, original.photoJPEGData)
        XCTAssertEqual(retained.snapshot.receiptPreviewPNGData, original.receiptPreviewPNGData)
        XCTAssertEqual(retained.snapshot.thermalPreviewPNGData, original.thermalPreviewPNGData)
        XCTAssertEqual(retained.snapshot.galleryURL, original.galleryURL)
        XCTAssertEqual(try recovery.retainedSessions().count, 1, "Repeated close does not duplicate retained assets")
        XCTAssertEqual(try CheckoutCheckpointStore(directory: root).unresolved[0].eventID, "original-event")
        XCTAssertEqual(retained.checkpoint.policyRevisionID, "original-policy")
        XCTAssertEqual(retained.checkpoint.copies, 3)
        XCTAssertEqual(try recovery.loadChecked()?.photoJPEGData, original.photoJPEGData)
    }

    func testRetentionFailureCannotParkOrDiscardOriginal() throws {
        let store = try CheckoutCheckpointStore(directory: root)
        try store.begin(checkpoint(phase: .claimed))
        let recovery = try AppRecoveryStore(directoryURL: root.appendingPathComponent("recovery"))
        let original = snapshot()
        try recovery.saveCritical(original)
        var detached = DetachedCheckoutStore(directory: root.appendingPathComponent("detached"))
        detached.writer = { _, _ in throw CocoaError(.fileWriteOutOfSpace) }
        XCTAssertThrowsError(try CheckoutInteractionClosure.close(id: "original", reason: "left", checkpoints: store, recovery: recovery, detached: detached, snapshot: original))
        XCTAssertFalse(store.unresolved[0].isParked)
        XCTAssertEqual(try recovery.loadChecked()?.photoJPEGData, original.photoJPEGData)
    }

    func testParkedPaymentUsesScopedGatesAndKeepsConnectionProtected() throws {
        let checkpoints = try CheckoutCheckpointStore(directory: root), outbox = try PrintOutcomeOutbox(directory: root)
        try checkpoints.begin(checkpoint(phase: .claimed))
        func decision(_ operation: SessionSetupSafety.Operation, busy: Bool = false, receipt: Bool = false) -> SessionSetupSafety.Decision {
            SessionSetupSafety.decision(for: operation, activeGuest: false, printerWorking: busy, needsReceiptCheck: receipt,
                hasPendingSession: false, checkpoints: checkpoints, outbox: outbox)
        }
        XCTAssertFalse(decision(.changeEvent).allowed)
        XCTAssertTrue(checkpoints.park(id: "original", reason: "guest left"))
        for operation in [SessionSetupSafety.Operation.openRegularBooth, .startUnrelatedGuest, .saveSettings, .changeEvent, .initiatePaidCheckout, .sendCopy] {
            XCTAssertTrue(decision(operation).allowed, "\(operation) is isolated from the old checkout")
        }
        XCTAssertFalse(decision(.changePaymentConnection).allowed)
        XCTAssertFalse(decision(.changeEvent, busy: true).allowed)
        XCTAssertEqual(decision(.changeEvent, receipt: true).destination, .recovery)
        XCTAssertFalse(decision(.changeEvent, receipt: true).allowed)
        XCTAssertTrue(decision(.saveSettings, busy: true, receipt: true).allowed)
    }

    func testInterruptedSendRequiresDurableRecoveryAndExactInspection() throws {
        let disk = ResolutionDisk(), journal = try PrintOutcomeOutbox(directory: root, writer: disk.write)
        try begin(journal)
        let originalBytes = try Data(contentsOf: root.appendingPathComponent("PaymentState/print-outbox.json"))
        disk.fails = true
        XCTAssertEqual(journal.recoverAfterLaunch(), 0)
        XCTAssertTrue(journal.hasUnfinishedPhysicalSend)
        XCTAssertNotNil(journal.persistenceFailure)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("PaymentState/print-outbox.json")), originalBytes)
        disk.fails = false
        journal.retryLaunchRecovery()
        XCTAssertFalse(journal.hasUnfinishedPhysicalSend)
        XCTAssertNil(journal.persistenceFailure)
        XCTAssertEqual(journal.entries[0].localState, .uncertain)
        let inspected = journal.inspectionEntryIDs
        XCTAssertFalse(inspected.isEmpty)
        disk.fails = true
        XCTAssertThrowsError(try journal.acknowledgeInspection(entryIDs: inspected))
        XCTAssertEqual(journal.inspectionEntryIDs, inspected)
        disk.fails = false
        try journal.acknowledgeInspection(entryIDs: inspected)
        let relaunched = try PrintOutcomeOutbox(directory: root)
        XCTAssertTrue(relaunched.inspectionEntryIDs.isEmpty)
        XCTAssertEqual(relaunched.entries[0].localState, .uncertain)
        XCTAssertThrowsError(try begin(relaunched))
        try begin(relaunched, batch: "new-batch")
        relaunched.finishCopy(batchID: "new-batch", copyIndex: 1, state: .uncertain)
        XCTAssertThrowsError(try relaunched.acknowledgeInspection(entryIDs: inspected), "An old acknowledgement cannot inspect a new copy")
        XCTAssertFalse(relaunched.inspectionEntryIDs.isEmpty)
    }

    func testNoBytesOutcomeCanRetryButUncertainOutcomeCannot() throws {
        let outbox = try PrintOutcomeOutbox(directory: root)
        try begin(outbox)
        XCTAssertTrue(outbox.finishCopy(batchID: "original-batch", copyIndex: 1, state: .notStarted))
        XCTAssertTrue(outbox.inspectionEntryIDs.isEmpty)
        XCTAssertEqual(outbox.nextCopyToPrint(batchID: "original-batch", copyCount: 3), 1)
        try begin(outbox)
        XCTAssertTrue(outbox.finishCopy(batchID: "original-batch", copyIndex: 1, state: .uncertain))
        XCTAssertThrowsError(try begin(outbox))
        XCTAssertEqual(outbox.nextCopyToPrint(batchID: "original-batch", copyCount: 3), 2)
    }

    func testFailedFinalOutcomeAndCompletionAreRetriedWithoutTransport() throws {
        let disk = ResolutionDisk(), outbox = try PrintOutcomeOutbox(directory: root, writer: disk.write)
        try begin(outbox)
        disk.fails = true
        XCTAssertFalse(outbox.finishCopy(batchID: "original-batch", copyIndex: 1, state: .notStarted))
        XCTAssertFalse(outbox.enqueueCompletion(batchID: "other", sessionID: "paid", entitlementID: "paid-entitlement"))
        XCTAssertNotNil(outbox.persistenceFailure)
        disk.fails = false
        outbox.retryLaunchRecovery()
        XCTAssertNil(outbox.persistenceFailure)
        XCTAssertEqual(outbox.entries.first?.localState, .notStarted)
        XCTAssertEqual(outbox.entries.filter { $0.kind == .completion }.count, 1)
        XCTAssertFalse(outbox.hasUnfinishedPhysicalSend)
    }

    func testCorruptRecordsRemainBlockedOnEveryRelaunch() throws {
        let folder = root.appendingPathComponent("PaymentState")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for file in ["print-outbox.json", "checkout-checkpoints.json"] { try Data("broken protected data".utf8).write(to: folder.appendingPathComponent(file)) }
        for _ in 0..<2 {
            let checkpoints = try CheckoutCheckpointStore(directory: root), outbox = try PrintOutcomeOutbox(directory: root)
            XCTAssertNotNil(checkpoints.integrityFault)
            XCTAssertNotNil(outbox.integrityFault)
            XCTAssertNotNil(SessionSetupSafety.recoveryIssue(needsReceiptCheck: false, hasPendingSession: false, checkpoints: checkpoints, outbox: outbox))
        }
        let journal = try PrintOutcomeOutbox(directory: root)
        XCTAssertThrowsError(try journal.acknowledgeInspection(entryIDs: []))
        XCTAssertFalse(journal.enqueueCompletion(batchID: "x", sessionID: "x", entitlementID: "x"))
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("print-outbox.json"), encoding: .utf8), "broken protected data")
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("checkout-checkpoints.json"), encoding: .utf8), "broken protected data")
    }

    func testDurableAcknowledgementSurvivesPreferencesLossAndDistinctCheckpoint() throws {
        let store = try AppRecoveryStore(directoryURL: root)
        let name = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let original = snapshot(stage: .printStatusUnknown)
        let identity = try OperatorRecoveryAcknowledgement.retainAndAcknowledge(original, store: store, defaults: defaults)
        defaults.removeObject(forKey: OperatorRecoveryAcknowledgement.key)
        XCTAssertEqual(try AppRecoveryStore(directoryURL: root).acknowledgedIdentity, identity)
        var newer = original; newer.checkpointID = UUID().uuidString
        XCTAssertNotEqual(OperatorRecoveryAcknowledgement.identity(newer), identity, "Same session/timestamp can still be a new physical failure")
    }

    func testResumingAndClosingAgainRetainsBothDecisions() throws {
        let store = try CheckoutCheckpointStore(directory: root)
        try store.begin(checkpoint(phase: .claimed))
        XCTAssertTrue(store.park(id: "original", reason: "first guest left"))
        let first = try XCTUnwrap(store.checkpoint(id: "original")?.localClosureHistory?.first)
        XCTAssertTrue(store.update(id: "original") { $0.locallyClosedAt = nil; $0.localCloseReason = nil; $0.detachedAt = nil })
        XCTAssertTrue(store.park(id: "original", reason: "guest resumed then left"))
        let restored = try CheckoutCheckpointStore(directory: root)
        XCTAssertEqual(restored.checkpoint(id: "original")?.localClosureHistory?.map(\.reason), ["first guest left", "guest resumed then left"])
        XCTAssertEqual(restored.checkpoint(id: "original")?.localClosureHistory?.first?.closedAt.timeIntervalSince1970.rounded(.down), first.closedAt.timeIntervalSince1970.rounded(.down))
    }

    func testCorruptGuestCheckpointCannotBeClearedByCancellation() throws {
        let store = try AppRecoveryStore(directoryURL: root)
        let file = URL(fileURLWithPath: store.storagePath)
        let original = Data("protected unreadable guest checkpoint".utf8)
        try original.write(to: file)
        XCTAssertThrowsError(try store.loadChecked())
        store.clear(sessionIdentifier: "original")
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    func testResumeRetainsOriginalPhotosAndCannotOverwriteAnotherUnclosedGuest() throws {
        let checkpoints = try CheckoutCheckpointStore(directory: root)
        try checkpoints.begin(checkpoint(phase: .claimed))
        let recovery = try AppRecoveryStore(directoryURL: root.appendingPathComponent("recovery"))
        let detached = DetachedCheckoutStore(directory: root.appendingPathComponent("detached"))
        let original = snapshot()
        try recovery.saveCritical(original)
        let resumed = try CheckoutInteractionClosure.snapshotForResume(id: "original", checkpoints: checkpoints, recovery: recovery, detached: detached)
        XCTAssertEqual(resumed?.photoJPEGData, original.photoJPEGData)
        XCTAssertEqual(try recovery.retainedSessions().first?.photoJPEGData, original.photoJPEGData)
        let other = snapshot("other-unclosed-guest")
        try recovery.saveCritical(other)
        XCTAssertThrowsError(try CheckoutInteractionClosure.snapshotForResume(id: "original", checkpoints: checkpoints, recovery: recovery, detached: detached))
        XCTAssertEqual(try recovery.loadChecked()?.sessionIdentifier, other.sessionIdentifier)
        XCTAssertEqual(try recovery.loadChecked()?.photoJPEGData, other.photoJPEGData)
        XCTAssertTrue(checkpoints.park(id: "original", reason: "original guest left"))
        XCTAssertThrowsError(try CheckoutInteractionClosure.snapshotForResume(id: "original", checkpoints: checkpoints, recovery: recovery, detached: detached), "Closing the target cannot close a different guest")
    }

    func testUnavailableStorageNeverAllowsPaidOrPrintOperation() {
        for operation in [SessionSetupSafety.Operation.openRegularBooth, .startUnrelatedGuest, .changeEvent, .initiatePaidCheckout, .sendCopy, .changePaymentConnection] {
            XCTAssertFalse(SessionSetupSafety.decision(for: operation, activeGuest: false, printerWorking: false, needsReceiptCheck: false,
                hasPendingSession: false, checkpoints: nil, outbox: nil).allowed)
        }
    }

    func testCashClosureNeverChangesVerificationOrOriginalLedgerReference() throws {
        for method in ["OFFLINE_CASH", "CASH_DECLARED"] {
            let store = try CheckoutCheckpointStore(directory: root.appendingPathComponent(method))
            var original = checkpoint(method: method, phase: .claimed); original.offlineRecordID = "original-ledger"
            try store.begin(original)
            XCTAssertTrue(store.park(id: original.id, reason: "left"))
            let restored = try XCTUnwrap(CheckoutCheckpointStore(directory: root.appendingPathComponent(method)).unresolved.first)
            XCTAssertEqual(restored.method, method)
            XCTAssertEqual(restored.offlineRecordID, "original-ledger")
            XCTAssertNil(restored.resolution)
        }
    }
}
