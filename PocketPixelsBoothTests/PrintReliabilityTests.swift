import Foundation
import XCTest
@testable import PocketPixelsBooth

@MainActor
final class PrintReliabilityTests: XCTestCase {
    private var auditURL: URL!

    override func setUp() async throws {
        auditURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("print-audit-\(UUID().uuidString).json")
    }

    func testOperatorStatusRespectsSelectedTransportAndDoesNotCallBusyAFailure() {
        func status(_ mode: PrinterConnectionMode, bt: Bool = false, ready: Bool = false,
                    test: Bool = false, wifi: Bool = false, busy: Bool = false, uncertain: Bool = false) -> OperatorPrinterState {
            .resolve(mode: mode, bluetoothConnected: bt, bluetoothReady: ready, bluetoothNeedsTest: test,
                     wifiConnected: wifi, busy: busy, unresolved: uncertain)
        }
        XCTAssertEqual(status(.wifi, wifi: true), .connected)
        XCTAssertTrue(status(.wifi, wifi: true).acceptsJobs)
        XCTAssertEqual(status(.wifi, bt: true, ready: true), .disconnected)
        XCTAssertEqual(status(.bluetooth, wifi: true), .disconnected)
        XCTAssertEqual(status(.bluetooth, bt: true, ready: true), .ready)
        XCTAssertEqual(status(.auto, bt: true, test: true, wifi: true), .awaitingTest)
        XCTAssertEqual(status(.auto, wifi: true), .connected)
        XCTAssertEqual(status(.auto, bt: true, ready: true, busy: true), .busy)
        XCTAssertEqual(status(.wifi, wifi: true, busy: true, uncertain: true), .unresolved)
        XCTAssertFalse(OperatorPrinterState.awaitingTest.acceptsJobs)
        XCTAssertFalse(OperatorPrinterState.unresolved.acceptsJobs)
    }

    func testBusyPrinterSummaryDoesNotTellOperatorToRecoverOrReconnect() {
        let report = EventReadinessReport(checks: [
            .init(severity: .critical, title: "Printer", status: .pass, detail: "Connected"),
            .init(severity: .critical, title: "Print Queue", status: .fail, detail: "Busy")
        ], generatedAt: Date())
        let summary = OperatorStatusSummary(report: report, hasUnresolvedPrint: false,
            printerRequiresRecovery: false, pendingUploadCount: 0, galleryStorageError: false)
        XCTAssertEqual(summary.printer.label, "Printing")
        XCTAssertTrue(summary.summary.contains("busy"))
        XCTAssertTrue(summary.attentionItems.isEmpty)
    }

    func testRecoveryDiagnosticTextCanStartBeforeTextVerification() {
        let service = PrinterBluetoothService()
        service.confirmPrinterRestarted()
        var completed = false
        service.printQuickText { result, bytesStarted in
            completed = true
            XCTAssertFalse(bytesStarted)
            guard case .failure(.printerNotConnected) = result else {
                return XCTFail("Recovery text must reach connection validation, not fail its own text-test prerequisite: \(result)")
            }
        }
        XCTAssertTrue(completed)
        // A failed diagnostic must leave raster printing blocked.
        XCTAssertFalse(service.canPrintRaster)
        XCTAssertTrue(service.readinessMessage.contains("diagnostic text"))
        // Failure before bytes must release ownership so the operator can reconnect/retry.
        service.printQuickText { result, _ in
            guard case .failure(.printerNotConnected) = result else {
                return XCTFail("Diagnostic failure leaked printer job ownership")
            }
        }
    }

    func testBluetoothReadinessDoesNotClearRequiredRecoveryTextTest() async throws {
        let service = PrinterBluetoothService()
        service.confirmPrinterRestarted()
        let ready = try await service.waitUntilReady(timeout: 0)
        XCTAssertFalse(ready)
        XCTAssertFalse(service.canPrintRaster)
        XCTAssertTrue(service.readinessMessage.contains("diagnostic text"))
    }

    func testBluetoothReadinessDoesNotTreatDisconnectedPrinterAsReady() async throws {
        let service = PrinterBluetoothService()
        let ready = try await service.waitUntilReady(timeout: 0)
        XCTAssertFalse(ready)
        XCTAssertFalse(service.isConnectedAndReady)
    }

    func testCancelledBluetoothReadinessStopsBeforeConnectionPreparation() async {
        let service = PrinterBluetoothService()
        let check = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await service.waitUntilReady()
        }
        do {
            _ = try await check.value
            XCTFail("Cancelled checkout must stop its printer check")
        } catch is CancellationError {
            XCTAssertFalse(service.isConnectedAndReady)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testSingleCopyEnvelopeIntegrity() throws {
        let batchID = UUID()
        let envelope = try ReliabilityFixtures.envelope(
            seed: 1,
            sessionIdentifier: "PP-20260907-000001",
            batchID: batchID
        )

        try envelope.verifyPayloadIntegrity()
        XCTAssertEqual(envelope.batchID, batchID)
        XCTAssertEqual(envelope.copyIndex, 1)
        XCTAssertEqual(envelope.copyCount, 1)
        XCTAssertEqual(envelope.imageWidth, ThermalImageRasterizer.printWidth)
        XCTAssertEqual(envelope.payloadByteCount, envelope.payload.count)
        XCTAssertEqual(envelope.payloadFingerprint, envelope.payload.sha256HexString)
    }

    func testTenCopiesUseIdenticalFrozenPayload() async throws {
        let records = try await runCopies(count: 10, seed: 10)
        ReliabilityFixtures.assertSameBatchIdenticalPayload(records)
    }

    func testMultiCopyEnvelopeIntegrityForSupportedCopyCounts() async throws {
        for copies in [1, 2, 3, 5, 10] {
            let records = try await runCopies(count: copies, seed: copies)
            ReliabilityFixtures.assertSameBatchIdenticalPayload(records)
        }
    }

    func testSpoolerNeverAllowsConcurrentPhysicalJobs() async throws {
        let spooler = try makeSpooler()
        let fake = DeterministicFakePrinterTransport(scenario: .delayedSuccess(nanoseconds: 20_000_000))
        let envelopes = try (1...12).map {
            try ReliabilityFixtures.envelope(seed: $0, sessionIdentifier: "PP-20260907-\(String(format: "%06d", $0))")
        }

        await withTaskGroup(of: Void.self) { group in
            for envelope in envelopes {
                group.addTask { @MainActor in
                    _ = await spooler.submit(envelope: envelope, transport: fake.operation)
                }
            }
        }

        XCTAssertEqual(fake.records.count, envelopes.count)
        XCTAssertEqual(fake.maximumConcurrentPhysicalJobs, 1)
        XCTAssertNil(spooler.activeJobID)
    }

    func testFailureBeforeBytesDoesNotRequireUnsafeRecovery() async throws {
        let spooler = try makeSpooler()
        let fake = DeterministicFakePrinterTransport(scenario: .failureBeforeBytes("Bluetooth unavailable"))
        let result = await spooler.submit(envelope: try ReliabilityFixtures.envelope(seed: 12), transport: fake.operation)

        XCTAssertTrue(result.isFailure)
        XCTAssertFalse(spooler.requiresRecovery)
        XCTAssertEqual(fake.records.count, 1)
        XCTAssertFalse(fake.records[0].bytesStarted)
        let audit = try loadAudit()
        XCTAssertEqual(audit.last?.terminalResult, .failedBeforeBytes)
        XCTAssertEqual(audit.last?.bytesStarted, false)
    }

    func testBluetoothUnavailableBeforeBytesDoesNotRequireUnsafeRecovery() async throws {
        try await assertBeforeBytesFailureIsSafe(message: "BLE unavailable")
    }

    func testConnectionFailureBeforeBytesDoesNotRequireUnsafeRecovery() async throws {
        try await assertBeforeBytesFailureIsSafe(message: "Unable to connect")
    }

    func testTimeoutBeforeTransmissionDoesNotRequireUnsafeRecovery() async throws {
        try await assertBeforeBytesFailureIsSafe(message: "Timeout before transmission")
    }

    func testFailureAfterBytesLocksPrinterRecovery() async throws {
        let spooler = try makeSpooler()
        let fake = DeterministicFakePrinterTransport(scenario: .failureAfterBytes(byteCount: 1, "Disconnected after first byte"))
        let result = await spooler.submit(envelope: try ReliabilityFixtures.envelope(seed: 13), transport: fake.operation)

        XCTAssertTrue(result.isFailure)
        XCTAssertTrue(spooler.requiresRecovery)
        XCTAssertEqual(fake.records.count, 1)
        XCTAssertTrue(fake.records[0].bytesStarted)
        let audit = try loadAudit()
        XCTAssertEqual(audit.last?.terminalResult, .recoveryRequiredAfterBytes)
        XCTAssertEqual(audit.last?.bytesStarted, true)
    }

    func testFailureHalfwayLocksPrinterRecovery() async throws {
        let envelope = try ReliabilityFixtures.envelope(seed: 131)
        try await assertAfterBytesFailureRequiresRecovery(envelope: envelope, failureByteCount: envelope.payloadByteCount / 2)
    }

    func testFailureAtFinalByteLocksPrinterRecovery() async throws {
        let envelope = try ReliabilityFixtures.envelope(seed: 132)
        try await assertAfterBytesFailureRequiresRecovery(envelope: envelope, failureByteCount: envelope.payloadByteCount)
    }

    func testFailureAfterBytesNeverAutoRetries() async throws {
        let spooler = try makeSpooler()
        let fake = DeterministicFakePrinterTransport(scenario: .failureAfterBytes(byteCount: 50, "Mid-print timeout"))
        let envelope = try ReliabilityFixtures.envelope(seed: 14)

        _ = await spooler.submit(envelope: envelope, transport: fake.operation)
        let second = await spooler.submit(envelope: envelope, transport: fake.operation)

        XCTAssertTrue(second.isFailure)
        XCTAssertEqual(fake.records.count, 1)
        XCTAssertTrue(spooler.requiresRecovery)
        let audit = try loadAudit()
        XCTAssertEqual(audit.count, 2)
        XCTAssertEqual(audit[0].terminalResult, .recoveryRequiredAfterBytes)
        XCTAssertEqual(audit[1].terminalResult, .failedBeforeBytes)
    }

    func testNextCopyDoesNotStartAfterUnknownPrintFailure() async throws {
        let spooler = try makeSpooler()
        let fake = DeterministicFakePrinterTransport(scenario: .failureAfterBytes(byteCount: 256, "Final chunk failed"))
        let batchID = UUID()

        for copy in 1...5 {
            let envelope = try ReliabilityFixtures.envelope(
                seed: 15,
                sessionIdentifier: "PP-20260907-BATCH",
                batchID: batchID,
                copyIndex: copy,
                copyCount: 5
            )
            let result = await spooler.submit(envelope: envelope, transport: fake.operation)
            if result.isFailure {
                break
            }
        }

        XCTAssertEqual(fake.records.count, 1)
        XCTAssertEqual(fake.records.first?.copyIndex, 1)
        XCTAssertTrue(spooler.requiresRecovery)
    }

    func testPrintAuditMatchesExecutedJobs() async throws {
        let spooler = try makeSpooler()
        let fake = DeterministicFakePrinterTransport()
        let records = try await runCopies(count: 3, seed: 16, spooler: spooler, fake: fake)

        let audit = try loadAudit()
        XCTAssertEqual(audit.count, 3)
        for (auditRecord, fakeRecord) in zip(audit, records) {
            XCTAssertEqual(auditRecord.jobID, fakeRecord.jobID)
            XCTAssertEqual(auditRecord.batchID, fakeRecord.batchID)
            XCTAssertEqual(auditRecord.sessionIdentifier, fakeRecord.sessionIdentifier)
            XCTAssertEqual(auditRecord.copyIndex, fakeRecord.copyIndex)
            XCTAssertEqual(auditRecord.copyCount, fakeRecord.copyCount)
            XCTAssertEqual(auditRecord.payloadFingerprint, fakeRecord.fingerprint)
            XCTAssertEqual(auditRecord.payloadByteCount, fakeRecord.payloadByteCount)
            XCTAssertEqual(auditRecord.terminalResult, .completed)
            XCTAssertTrue(auditRecord.bytesStarted)
        }
    }

    func testDuplicateCompletionCallbackIsRejectedByLifecycle() {
        var lifecycle = BluetoothPrinterJobLifecycle()
        let jobID = lifecycle.beginJob()
        XCTAssertNotNil(jobID)
        XCTAssertEqual(lifecycle.scheduleTransportCompletion(expectedJobID: jobID!), .accepted)
        XCTAssertEqual(lifecycle.scheduleTransportCompletion(expectedJobID: jobID!), .duplicate)
        XCTAssertEqual(lifecycle.finishJob(expectedJobID: jobID!), .accepted)
        XCTAssertEqual(lifecycle.finishJob(expectedJobID: jobID!), .stale(activeJobID: nil))
    }

    private func runCopies(
        count: Int,
        seed: Int,
        spooler: PrintSpooler? = nil,
        fake: DeterministicFakePrinterTransport? = nil
    ) async throws -> [DeterministicFakePrinterTransport.Record] {
        let spooler = try spooler ?? makeSpooler()
        let fake = fake ?? DeterministicFakePrinterTransport()
        let batchID = UUID()
        let sessionID = "PP-20260907-\(String(format: "%06d", seed))"
        for copy in 1...count {
            let envelope = try ReliabilityFixtures.envelope(
                seed: seed,
                sessionIdentifier: sessionID,
                batchID: batchID,
                copyIndex: copy,
                copyCount: count
            )
            let result = await spooler.submit(envelope: envelope, transport: fake.operation)
            XCTAssertTrue(result.isSuccess)
        }
        return fake.records
    }

    private func makeSpooler() throws -> PrintSpooler {
        PrintSpooler(
            auditStore: try PrintAuditStore(fileURL: auditURL),
            waitsForPhysicalHandoff: false,
            writesAuditSynchronously: true
        )
    }

    private func assertBeforeBytesFailureIsSafe(message: String) async throws {
        let spooler = try makeSpooler()
        let fake = DeterministicFakePrinterTransport(scenario: .failureBeforeBytes(message))
        let result = await spooler.submit(envelope: try ReliabilityFixtures.envelope(seed: message.count), transport: fake.operation)

        XCTAssertTrue(result.isFailure)
        XCTAssertFalse(spooler.requiresRecovery)
        XCTAssertEqual(fake.records.count, 1)
        XCTAssertFalse(fake.records[0].bytesStarted)
    }

    private func assertAfterBytesFailureRequiresRecovery(envelope: PrintJobEnvelope, failureByteCount: Int) async throws {
        let spooler = try makeSpooler()
        let fake = DeterministicFakePrinterTransport(scenario: .failureAfterBytes(byteCount: failureByteCount, "Uncertain completion"))
        let result = await spooler.submit(envelope: envelope, transport: fake.operation)

        XCTAssertTrue(result.isFailure)
        XCTAssertTrue(spooler.requiresRecovery)
        XCTAssertEqual(fake.records.count, 1)
        XCTAssertTrue(fake.records[0].bytesStarted)
        XCTAssertEqual(try loadAudit().last?.terminalResult, .recoveryRequiredAfterBytes)
    }

    private func loadAudit() throws -> [PrintAuditRecord] {
        try PrintAuditStore(fileURL: auditURL).load()
    }
}

private extension Result {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }

    var isFailure: Bool {
        if case .failure = self { return true }
        return false
    }
}
