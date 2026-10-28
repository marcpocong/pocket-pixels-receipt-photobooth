import XCTest
import UIKit
@testable import PocketPixelsBooth

@MainActor final class OperatorFreedomReleaseTests: XCTestCase {
    private var root: URL!
    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("operator-freedom-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    private func checkpoint(_ id: String) -> CheckoutCheckpoint {
        .init(id: id, environment: "test", deviceID: "test-ipad", accountID: "owner", eventID: "cim-test-event",
              policyRevisionID: "frozen-policy", unitPriceCentavos: 5000, copies: 8, format: "solo", method: "QRPH",
              orderID: "original-order", entitlementID: "original-entitlement", phase: .printing,
              lastServerState: "PAID_VERIFIED", createdAt: Date(), updatedAt: Date())
    }
    private func archive(sessionID: String) throws -> (RecentSessionArchiveStore, RecentSessionArchive) {
        let store = try RecentSessionArchiveStore(directoryURL: root.appendingPathComponent("archive"))
        let photo = ReliabilityFixtures.syntheticPhoto(session: 8, photo: 1, format: .solo)
        var profile = EventProfile.pocketPixelsDefault; profile.isEnabled = true; profile.eventName = "CIM INTRAMS · SIMULATION"
        let session = CommittedGallerySession(sessionIdentifier: sessionID, createdAt: Date(timeIntervalSince1970: 1_793_000_000),
            galleryToken: String(repeating: "c", count: 64), galleryURL: URL(string: "https://example.test/retained")!,
            photos: [photo], format: .solo, eventProfile: profile)
        let receipt = try ReceiptComposer.compose(photos: [photo], sessionIdentifier: sessionID, date: session.createdAt,
            galleryURL: session.galleryURL, format: .solo, eventProfile: profile)
        let raster = try ThermalImageRasterizer.rasterize(XCTUnwrap(UIImage(data: receipt.imagePNGData)), purpose: .completeReceipt)
        try store.save(.init(committedSession: session, composedReceipt: receipt, receiptPreviewPNGData: receipt.imagePNGData,
            thermalPreviewPNGData: raster.previewPNGData, rasterizedImage: raster, photoThumbnailData: [], eventRunID: "original-run"))
        try store.attachOriginalPhotos(archiveID: session.galleryToken, sessionID: sessionID, photos: [try XCTUnwrap(photo.jpegData(compressionQuality: 0.95))])
        return (store, try store.load(archiveID: session.galleryToken))
    }
    private func spooler(_ filename: String = "audit.json") throws -> PrintSpooler {
        PrintSpooler(auditStore: try PrintAuditStore(fileURL: root.appendingPathComponent(filename)), waitsForPhysicalHandoff: false, writesAuditSynchronously: true)
    }
    private func send(_ envelope: PrintJobEnvelope, via coordinator: PrinterCoordinator) async -> Result<Void, Error> {
        await withCheckedContinuation { continuation in
            coordinator.printEnvelope(envelope, wifiHost: "test.invalid", wifiPort: 9100, completion: { continuation.resume(returning: $0) })
        }
    }
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Operation did not reach its terminal state")
    }

    func testCIMEightCopyInterruptionRelaunchExactReplacementDiagnosticSampleAndEnd() async throws {
        let sessionID = "cim-simulated-guest"
        let (archives, original) = try archive(sessionID: sessionID)
        let originalRaster = original.rasterizedImage.rasterCommand
        var outbox = try PrintOutcomeOutbox(directory: root)
        let checkpoints = try CheckoutCheckpointStore(directory: root)
        try checkpoints.begin(checkpoint(sessionID))
        let recovery = try AppRecoveryStore(directoryURL: root.appendingPathComponent("recovery"))
        let snapshot = AppRecoverySnapshot(schemaVersion: 1, sessionIdentifier: sessionID, createdAt: Date(), format: .solo,
            eventProfile: .pocketPixelsDefault, galleryToken: original.summary.archiveID, galleryURL: URL(string: "https://example.test/retained"),
            photoJPEGData: [Data([1, 2, 3])], receiptPreviewPNGData: original.receiptPreviewPNGData,
            thermalPreviewPNGData: original.thermalPreviewPNGData, rasterFingerprint: original.summary.rasterFingerprint,
            stage: .printStatusUnknown, updatedAt: Date(), checkpointID: UUID().uuidString)
        try recovery.saveCritical(snapshot)
        let batch = UUID(), physical = try spooler()
        let success = DeterministicFakePrinterTransport(), failure = DeterministicFakePrinterTransport(scenario: .failureAfterBytes(byteCount: 128, "copy 7 interrupted"))
        for copy in 1...8 {
            let job = try PrintJobEnvelope.receipt(rasterizedImage: original.rasterizedImage, sessionIdentifier: sessionID,
                source: .liveCustomer, copyIndex: copy, copyCount: 8, batchID: batch, transportPolicy: .safeIntegrity)
            let result = await physical.submit(envelope: job, prePrintCheckpoint: { job in
                try outbox.beginCopy(batchID: batch.uuidString.lowercased(), sessionID: sessionID, entitlementID: "original-entitlement",
                    receiptFingerprint: job.payloadFingerprint, copyIndex: copy, copyCount: 8, transport: "bluetooth")
            }, transport: copy == 7 ? failure.operation : success.operation)
            switch result {
            case .success: XCTAssertTrue(outbox.finishCopy(batchID: batch.uuidString.lowercased(), copyIndex: copy, state: .delivered))
            case .failure:
                XCTAssertTrue(outbox.finishCopy(batchID: batch.uuidString.lowercased(), copyIndex: copy, state: .uncertain))
            }
            if case .failure = result { break }
        }
        XCTAssertEqual(success.records.count, 6)
        XCTAssertEqual(failure.records.map(\.copyIndex), [7])
        let summary = InterruptedPrintSummary(entries: outbox.latestBatchEntries(sessionID: sessionID))
        XCTAssertEqual(summary.requested, 8); XCTAssertEqual(summary.reported, 6)
        XCTAssertEqual(summary.uncertain, 1); XCTAssertEqual(summary.notStarted, 1)
        outbox = try PrintOutcomeOutbox(directory: root)
        XCTAssertEqual(outbox.entries.count, 7, "Relaunch sends nothing; copy 8 was never attempted")
        try outbox.acknowledgeInspection(entryIDs: outbox.inspectionEntryIDs)
        physical.confirmPrinterRestarted()
        let acknowledgedOriginal = try PrintOutcomeOutbox(directory: root).entries
        XCTAssertEqual(acknowledgedOriginal.last?.localState, .uncertain)
        XCTAssertNotNil(acknowledgedOriginal.last?.hardwareAcknowledgedAt)
        // A new process sees the same acknowledgment and original unknown outcome.
        outbox = try PrintOutcomeOutbox(directory: root)
        XCTAssertTrue(outbox.inspectionEntryIDs.isEmpty)
        let replacementTransport = DeterministicFakePrinterTransport()
        let coordinator = PrinterCoordinator(spooler: physical, outbox: { outbox }, authorized: { true }, readiness: { nil }, transport: replacementTransport.operation)
        let reprint = ArchivedReceiptReprintController(printerCoordinator: coordinator, archiveStore: { archives })
        reprint.increaseQuantity(); XCTAssertEqual(reprint.quantity, 2)
        XCTAssertTrue(reprint.canReprint)
        var replacementCopies = 0
        reprint.reprint(archive: original, wifiHost: "test.invalid", wifiPort: 9100) { replacementCopies += $0 }
        // Repeated tap does not schedule a duplicate batch.
        reprint.reprint(archive: original, wifiHost: "test.invalid", wifiPort: 9100) { replacementCopies += $0 }
        try await waitUntil { !reprint.isReprinting }
        XCTAssertEqual(replacementCopies, 2)
        XCTAssertEqual(replacementTransport.records.count, 2)
        XCTAssertEqual(Set(replacementTransport.records.map(\.batchID)).count, 1)
        XCTAssertNotEqual(replacementTransport.records.first?.batchID, batch)
        XCTAssertTrue(replacementTransport.records.allSatisfy { $0.source == .archivedReprint && $0.sessionIdentifier == sessionID })
        XCTAssertEqual(outbox.entries.filter { $0.batchID == batch.uuidString.lowercased() }, acknowledgedOriginal)
        XCTAssertTrue(outbox.entries.filter { $0.source == .archivedReprint }.allSatisfy { $0.entitlementID == nil })
        XCTAssertEqual(try archives.load(archiveID: original.summary.archiveID).rasterizedImage.rasterCommand, originalRaster)
        XCTAssertEqual(checkpoints.checkpoint(id: sessionID)?.orderID, "original-order")
        XCTAssertEqual(checkpoints.checkpoint(id: sessionID)?.copies, 8)
        XCTAssertNil(checkpoints.checkpoint(id: sessionID)?.resolvedAt)
        coordinator.quickTestPrint()
        try await waitUntil { coordinator.quickTestMessage == "Test sent. Check the paper." }
        XCTAssertEqual(replacementTransport.records.last?.source, .diagnostic)
        XCTAssertTrue(SamplePrintPolicy.canStart(hasPreview: true, printerBusy: false, recoveryLocked: false,
            unresolvedPrint: true, operationActive: false, guestSessionActive: false))
        let sample = try ReliabilityFixtures.envelope(seed: 91, sessionIdentifier: SamplePrintPolicy.auditSessionIdentifier, source: .operatorSample)
        let sampleResult = await send(sample, via: coordinator)
        if case .failure(let error) = sampleResult { XCTFail(error.localizedDescription) }
        XCTAssertEqual(replacementTransport.records.last?.source, .operatorSample)
        let booth = Booth(); defer { booth.cleanup() }
        let setup = booth.setup(); await setup.createEvent(name: "CIM INTRAMS · SIMULATION", venue: "Test")
        let started = await setup.startAccepting(); XCTAssertTrue(started, setup.message)
        let run = try XCTUnwrap(booth.runs.current)
        try booth.runs.beginSession(id: sessionID, runID: run.id, format: "solo")
        await booth.runs.reconcilePrintEvidence(outbox.entries)
        XCTAssertEqual(try booth.runs.session(id: sessionID)?.printOutcomes.count, 7, "Replacement copies cannot inflate guest statistics")
        XCTAssertNil(try booth.runs.session(id: sessionID)?.completedAt, "Replacements cannot complete the original uncertain guest batch")
        // Ending does not require a second hardware check, nor financial settlement.
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let lifecycle = booth.lifecycle {
            try CheckoutInteractionClosure.retainForEventEnd(checkpoints: checkpoints, recovery: recovery,
                detached: DetachedCheckoutStore(directory: self.root.appendingPathComponent("detached")), defaults: defaults)
        }
        let ended = await lifecycle.end(scope: .thisBooth); XCTAssertTrue(ended, lifecycle.message)
        booth.relaunch()
        XCTAssertEqual(booth.runs.runs.first?.status, .completed)
        XCTAssertEqual(try booth.runs.session(id: sessionID)?.runID, run.id)
        let retainedCheckpoint = try XCTUnwrap(try CheckoutCheckpointStore(directory: root).checkpoint(id: sessionID))
        XCTAssertTrue(retainedCheckpoint.isParked); XCTAssertFalse(retainedCheckpoint.isResolved)
        XCTAssertEqual(retainedCheckpoint.orderID, "original-order"); XCTAssertEqual(retainedCheckpoint.entitlementID, "original-entitlement")
        XCTAssertEqual(try recovery.retainedSessions().first?.photoJPEGData, snapshot.photoJPEGData)
        XCTAssertEqual(outbox.entries.filter { $0.batchID == batch.uuidString.lowercased() }, acknowledgedOriginal)
        // Original archive remains intentionally printable after the event ends.
        reprint.reprint(archive: original, wifiHost: "test.invalid", wifiPort: 9100) { replacementCopies += $0 }
        try await waitUntil { !reprint.isReprinting }
        XCTAssertEqual(replacementCopies, 4)
        let nextGuest = try await booth.admitGuest(session: "next-regular-guest")
        XCTAssertEqual(nextGuest, "regular-booth")
        XCTAssertEqual(replacementTransport.maximumConcurrentPhysicalJobs, 1)
        XCTAssertEqual(try PrintAuditStore(fileURL: root.appendingPathComponent("audit.json")).load().filter { $0.source == .archivedReprint }.count, 4)
    }

    func testEightCopyBatchStopsAtFirstOrFinalFailureWithCorrectKnownAndUnknownCounts() async throws {
        for failingCopy in [1, 8] {
            for bytes in [false, true] {
                let outbox = try PrintOutcomeOutbox(directory: root.appendingPathComponent("boundary-\(failingCopy)-\(bytes)"))
                let physical = try spooler("boundary-\(failingCopy)-\(bytes).json"), batch = UUID()
                let success = DeterministicFakePrinterTransport()
                let failure = DeterministicFakePrinterTransport(scenario: bytes ? .failureAfterBytes(byteCount: 100, "copy/cut failure") : .failureBeforeBytes("disconnected"))
                for copy in 1...8 {
                    let job = try ReliabilityFixtures.envelope(seed: 8, sessionIdentifier: "boundary-test", batchID: batch, copyIndex: copy, copyCount: 8)
                    let result = await physical.submit(envelope: job, prePrintCheckpoint: { job in
                        try outbox.beginCopy(batchID: batch.uuidString, sessionID: job.sessionIdentifier, entitlementID: nil,
                            receiptFingerprint: job.payloadFingerprint, copyIndex: copy, copyCount: 8, transport: "bluetooth")
                    }, transport: copy == failingCopy ? failure.operation : success.operation)
                    switch result {
                    case .success: XCTAssertTrue(outbox.finishCopy(batchID: batch.uuidString, copyIndex: copy, state: .delivered))
                    case .failure: XCTAssertTrue(outbox.finishCopy(batchID: batch.uuidString, copyIndex: copy, state: bytes ? .uncertain : .notStarted))
                    }
                    if case .failure = result { break }
                }
                let counts = InterruptedPrintSummary(entries: outbox.entries)
                XCTAssertEqual(counts.reported, failingCopy - 1)
                XCTAssertEqual(counts.uncertain, bytes ? 1 : 0)
                XCTAssertEqual(counts.notStarted, 8 - counts.reported - counts.uncertain)
                XCTAssertEqual(success.records.count + failure.records.count, failingCopy)
                XCTAssertEqual(failure.records.count, 1)
            }
        }
    }

    func testReplacementCopiesCannotFulfillOriginalPaidEntitlementOrCompleteGuestStatistics() async throws {
        let outbox = try PrintOutcomeOutbox(directory: root)
        for copy in 1...2 {
            try outbox.beginCopy(batchID: "replacement", sessionID: "paid-guest", entitlementID: nil,
                receiptFingerprint: "frozen-raster", copyIndex: copy, copyCount: 2, transport: "bluetooth", source: .archivedReprint)
            XCTAssertTrue(outbox.finishCopy(batchID: "replacement", copyIndex: copy, state: .delivered))
        }
        XCTAssertTrue(outbox.copiesThatMayHavePrinted(sessionID: "paid-guest").isEmpty)
        XCTAssertFalse(PaymentRecoveryCoordinator.allPaidCopiesDelivered(outbox.entries, paidCopies: 2))
        let runs = EventRunStore(directory: root.appendingPathComponent("runs"), authorized: { true }, blockingReason: { nil })
        let run = try runs.startNewRun(context: .init(designID: "original", commercialEventID: "paid-event", serverBinding: "original", name: "Test"))
        try runs.beginSession(id: "paid-guest", runID: run.id, format: "solo")
        await runs.reconcilePrintEvidence(outbox.entries)
        let record = try XCTUnwrap(runs.session(id: "paid-guest"))
        XCTAssertTrue(record.printOutcomes.isEmpty); XCTAssertNil(record.completedAt)
        XCTAssertNil(outbox.latestInterruptedSessionID)
    }

    func testOperatorDuplicateTapCannotQueueAnotherPhysicalCommand() async throws {
        let outbox = try PrintOutcomeOutbox(directory: root), fake = DeterministicFakePrinterTransport(scenario: .delayedSuccess(nanoseconds: 50_000_000))
        let coordinator = PrinterCoordinator(spooler: try spooler(), outbox: { outbox }, authorized: { true }, readiness: { nil }, transport: fake.operation)
        let job = try ReliabilityFixtures.envelope(seed: 1, source: .diagnostic)
        var completions = 0, failures = 0
        for _ in 0..<6 {
            coordinator.printEnvelope(job, wifiHost: "test.invalid", wifiPort: 9100, completion: {
                completions += 1; if case .failure = $0 { failures += 1 }
            })
        }
        try await waitUntil { completions == 6 }
        XCTAssertEqual(fake.records.count, 1); XCTAssertEqual(failures, 5)
        XCTAssertEqual(outbox.entries.count, 1)
    }

    func testUnauthorizedOperatorCannotDispatchOrCreateJournalEntry() async throws {
        let outbox = try PrintOutcomeOutbox(directory: root), fake = DeterministicFakePrinterTransport()
        let coordinator = PrinterCoordinator(spooler: try spooler(), outbox: { outbox }, authorized: { false }, readiness: { nil }, transport: fake.operation)
        let result = await send(try ReliabilityFixtures.envelope(seed: 2, source: .archivedReprint), via: coordinator)
        if case .success = result { XCTFail("Operator authentication required") }
        XCTAssertTrue(fake.records.isEmpty); XCTAssertTrue(outbox.entries.isEmpty)
    }

    func testOperatorFailureMatrixRetainsUncertaintyAcrossRelaunchWithoutRetry() async throws {
        for source in [PrintJobSource.archivedReprint, .operatorSample, .diagnostic] {
            for bytes in [false, true] {
                let directory = root.appendingPathComponent("\(source)-\(bytes)")
                let outbox = try PrintOutcomeOutbox(directory: directory)
                let fake = DeterministicFakePrinterTransport(scenario: bytes ? .failureAfterBytes(byteCount: 100, "finishing/disconnect") : .failureBeforeBytes("offline"))
                let coordinator = PrinterCoordinator(spooler: try spooler("\(source)-\(bytes).json"), outbox: { outbox }, authorized: { true }, readiness: { nil }, transport: fake.operation)
                _ = await send(try ReliabilityFixtures.envelope(seed: 3, source: source), via: coordinator)
                XCTAssertEqual(outbox.entries.last?.localState, bytes ? .uncertain : .notStarted)
                XCTAssertEqual(outbox.entries.last?.source, source)
                let relaunched = try PrintOutcomeOutbox(directory: directory)
                XCTAssertEqual(relaunched.entries.map(\.id), outbox.entries.map(\.id))
                XCTAssertEqual(relaunched.entries.map(\.localState), outbox.entries.map(\.localState))
                XCTAssertEqual(relaunched.entries.map(\.receiptFingerprint), outbox.entries.map(\.receiptFingerprint))
                XCTAssertEqual(relaunched.entries.map(\.entitlementID), outbox.entries.map(\.entitlementID))
                XCTAssertEqual(relaunched.entries.map(\.reportState), outbox.entries.map(\.reportState))
                XCTAssertEqual(fake.records.count, 1)
                XCTAssertEqual(relaunched.inspectionEntryIDs.isEmpty, !bytes)
            }
        }
    }

    func testFailureSavingSuccessfulOperatorOutcomeBlocksFurtherSendsAndRelaunchKeepsUnknown() async throws {
        final class Disk {
            var fails = false
            func write(_ data: Data, _ url: URL) throws {
                if fails { throw CocoaError(.fileWriteOutOfSpace) }
                try DurableFileWriter.write(data, to: url)
            }
        }
        let disk = Disk(), outbox = try PrintOutcomeOutbox(directory: root, writer: disk.write)
        let fake = DeterministicFakePrinterTransport()
        let coordinator = PrinterCoordinator(spooler: try spooler(), outbox: { outbox }, authorized: { true }, readiness: { nil }, transport: { job in
            let result = await fake.operation(envelope: job)
            disk.fails = true
            return result
        })
        _ = await send(try ReliabilityFixtures.envelope(seed: 4, source: .archivedReprint), via: coordinator)
        XCTAssertEqual(fake.records.count, 1)
        XCTAssertEqual(outbox.entries.last?.localState, .inFlight)
        XCTAssertNotNil(coordinator.operatorPrintBlockReason)
        _ = await send(try ReliabilityFixtures.envelope(seed: 5, source: .diagnostic), via: coordinator)
        XCTAssertEqual(fake.records.count, 1, "No resend after bytes or a journal failure")
        let relaunched = try PrintOutcomeOutbox(directory: root)
        XCTAssertEqual(relaunched.recoverAfterLaunch(), 1)
        XCTAssertEqual(relaunched.entries.last?.localState, .uncertain)
        XCTAssertFalse(relaunched.inspectionEntryIDs.isEmpty)
    }

    func testEventEndRetentionFailureLeavesAdmissionClosedAndEventUnsettled() async throws {
        let booth = Booth(); defer { booth.cleanup() }
        let setup = booth.setup(); await setup.createEvent(name: "Test", venue: "")
        let started = await setup.startAccepting(); XCTAssertTrue(started)
        let lifecycle = booth.lifecycle { throw CocoaError(.fileWriteOutOfSpace) }
        let ended = await lifecycle.end(scope: .thisBooth)
        XCTAssertFalse(ended); XCTAssertTrue(booth.acceptance.state.blocked)
        XCTAssertEqual(booth.runs.current?.status, .active)
        XCTAssertNil(booth.runs.pendingTransition)
    }

    func testCompletionCountdownFrozenDurationExtensionsNoRestartAndStaleSession() {
        let now = Date(timeIntervalSince1970: 1000)
        var countdown = CompletedSessionCountdown()
        countdown.start(generation: 1, printedGalleryQR: true, safe: false, now: now)
        XCTAssertNil(countdown.deadline, "Cleanup must finish first")
        countdown.start(generation: 1, printedGalleryQR: true, safe: true, now: now)
        XCTAssertEqual(countdown.deadline, now.addingTimeInterval(30))
        countdown.start(generation: 1, printedGalleryQR: false, safe: true, now: now.addingTimeInterval(20))
        XCTAssertEqual(countdown.deadline, now.addingTimeInterval(30), "Gallery updates/settings cannot restart a deadline")
        countdown.extend(generation: 1, now: now.addingTimeInterval(25))
        XCTAssertEqual(countdown.deadline, now.addingTimeInterval(60))
        countdown.extend(generation: 1, now: now.addingTimeInterval(55))
        XCTAssertEqual(countdown.deadline, now.addingTimeInterval(90))
        XCTAssertFalse(countdown.isDue(generation: 1, safe: false, now: now.addingTimeInterval(200)))
        XCTAssertFalse(countdown.isDue(generation: 2, safe: true, now: now.addingTimeInterval(200)))
        XCTAssertTrue(countdown.isDue(generation: 1, safe: true, now: now.addingTimeInterval(200)), "Foreground uses elapsed deadline")
        countdown.start(generation: 2, printedGalleryQR: false, safe: true, now: now)
        XCTAssertEqual(countdown.deadline, now.addingTimeInterval(60))
    }

    func testSampleExplicitReuseFillsRemainingSlotsAndPreparesAutomatically() async throws {
        let model = SamplePrintStudioModel()
        model.setFormat(.gridSix)
        let image = ReliabilityFixtures.syntheticPhoto(session: 1, photo: 1, format: .solo)
        model.addImported([SamplePrintPhoto(id: UUID(), image: image, thumbnail: image)])
        XCTAssertEqual(model.missingSlotCount, 5)
        model.fillEmptySlots(); XCTAssertEqual(model.missingSlotCount, 5, "No implicit reuse")
        model.fillEmptySlots(reusingPhotos: true)
        XCTAssertEqual(model.missingSlotCount, 0)
        try await waitUntil { model.printableSample != nil }
        let open = SamplePrintStudioModel.PrinterGate(printerBusy: false, recoveryLocked: false, unresolvedPrint: true, guestSessionActive: false)
        XCTAssertTrue(model.canPrint(open)); XCTAssertNil(model.blockedReason(open))
        var disconnected = open; disconnected.unavailableReason = "Printer disconnected. Reconnect to print."
        XCTAssertFalse(model.canPrint(disconnected)); XCTAssertEqual(model.blockedReason(disconnected), disconnected.unavailableReason)
    }

    func testCompletedModelDeadlineSurvivesUpdatesAndResetsOnlyTemporaryGuestState() throws {
        var environment = BoothSessionEnvironment.customer
        environment.recoveryDirectory = root.appendingPathComponent("completed-recovery")
        environment.recordsCustomerSessionMetrics = false
        let model = BoothSessionViewModel(environment: environment, eventRunStore: nil, checkpointStore: nil)
        model.state = .thankYou; model.sessionIdentifier = "finished-guest"; model.galleryToken = "frozen-gallery"
        let now = Date(timeIntervalSince1970: 1000)
        model.startCompletedCountdownIfReady(now: now)
        XCTAssertEqual(model.completedCountdown.deadline, now.addingTimeInterval(30))
        model.startCompletedCountdownIfReady(now: now.addingTimeInterval(10))
        XCTAssertEqual(model.completedCountdown.deadline, now.addingTimeInterval(30))
        model.resetCompletedSessionIfDue(now: now.addingTimeInterval(29)); XCTAssertEqual(model.state, .thankYou)
        model.resetCompletedSessionIfDue(now: now.addingTimeInterval(30)); XCTAssertEqual(model.state, .welcome)
        XCTAssertNil(model.galleryToken); XCTAssertNil(model.completedCountdown.deadline)
        model.state = .review; model.sessionIdentifier = "next-guest"
        model.resetCompletedSessionIfDue(now: now.addingTimeInterval(100))
        XCTAssertEqual(model.state, .review); XCTAssertEqual(model.sessionIdentifier, "next-guest")
    }

    func testReconnectIsIdempotentAndNeverInterruptsPhysicalWork() {
        XCTAssertEqual(PrinterReconnectPolicy.action(ready: true, connecting: false, transmitting: false), .keepHealthyConnection)
        XCTAssertEqual(PrinterReconnectPolicy.action(ready: false, connecting: true, transmitting: false), .joinExistingAttempt)
        XCTAssertEqual(PrinterReconnectPolicy.action(ready: true, connecting: false, transmitting: true), .waitForPhysicalJob)
        XCTAssertEqual(PrinterReconnectPolicy.action(ready: false, connecting: false, transmitting: false), .reconnect)
    }

    func testJournalPruningKeepsAllOriginalCopiesInAnAcknowledgedUncertainBatch() throws {
        let outbox = try PrintOutcomeOutbox(directory: root)
        for copy in 1...7 {
            try outbox.beginCopy(batchID: "original", sessionID: "original-session", entitlementID: nil,
                receiptFingerprint: "original-raster", copyIndex: copy, copyCount: 8, transport: "bluetooth")
            XCTAssertTrue(outbox.finishCopy(batchID: "original", copyIndex: copy, state: copy == 7 ? .uncertain : .delivered))
        }
        try outbox.acknowledgeInspection(entryIDs: outbox.inspectionEntryIDs)
        for index in 0..<(PrintOutcomeOutbox.retainedDeliveredCount + 2) {
            let batch = "operator-\(index)"
            try outbox.beginCopy(batchID: batch, sessionID: "operator", entitlementID: nil,
                receiptFingerprint: "sample-raster", copyIndex: 1, copyCount: 1, transport: "bluetooth", source: .operatorSample)
            XCTAssertTrue(outbox.finishCopy(batchID: batch, copyIndex: 1, state: .delivered))
        }
        let relaunched = try PrintOutcomeOutbox(directory: root)
        let original = relaunched.latestBatchEntries(sessionID: "original-session")
        XCTAssertEqual(original.count, 7)
        XCTAssertEqual(InterruptedPrintSummary(entries: original).reported, 6)
        XCTAssertEqual(InterruptedPrintSummary(entries: original).uncertain, 1)
        XCTAssertEqual(InterruptedPrintSummary(entries: original).notStarted, 1)
        XCTAssertTrue(relaunched.inspectionEntryIDs.isEmpty)
    }

    func testQuickDiagnosticUsesExistingFinishingWithoutCustomerData() throws {
        let raster = try QuickPrinterTest.raster()
        XCTAssertEqual(raster.width, 576); XCTAssertLessThanOrEqual(raster.height, 240)
        XCTAssertEqual(QuickPrinterTest.content, "MADE TO KEEP\nPRINTER TEST\n\nPAPER CHECK\n\nTEST ONLY")
        let job = try PrintJobEnvelope.diagnostic(heading: ThermalImageRasterizer.receiptPrintHeading(), rasterizedImage: raster,
            finishing: ThermalImageRasterizer.receiptPrintFinishing(), sessionIdentifier: "operator-quick-test", copyIndex: 1,
            copyCount: 1, batchID: UUID(), transportPolicy: .safeIntegrity)
        try job.verifyPayloadIntegrity()
        XCTAssertTrue(job.payload.suffix(ThermalImageRasterizer.receiptPrintFinishing().count).elementsEqual(ThermalImageRasterizer.receiptPrintFinishing()))
        XCTAssertEqual(job.source, .diagnostic)
    }
}
