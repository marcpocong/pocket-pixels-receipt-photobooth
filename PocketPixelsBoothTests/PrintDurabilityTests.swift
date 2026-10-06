import Foundation
import UIKit
import XCTest
@testable import PocketPixelsBooth

final class GalleryAuthenticationClassificationTests: XCTestCase {
    func testAuthCodesAreClassifiedEvenInsideHTTP200Body() throws {
        for code in ["MISSING_DEVICE_TOKEN", "INVALID_DEVICE_TOKEN", "SERVER_NOT_CONFIGURED"] {
            let data = Data("{\"ok\":false,\"schemaVersion\":1,\"errorCode\":\"\(code)\",\"error\":\"Upload is not authorized.\",\"status\":\"rejected\"}".utf8)
            let response = try JSONDecoder().decode(GalleryUploadResponse.self, from: data)
            XCTAssertTrue(GoogleDriveGalleryUploadService.isAuthenticationFailure(response))
        }
    }

    func testNonAuthBackendErrorIsNotMisclassified() throws {
        let data = Data("{\"ok\":false,\"schemaVersion\":1,\"errorCode\":\"INVALID_GALLERY_TOKEN\",\"error\":\"Invalid gallery token.\",\"status\":\"rejected\"}".utf8)
        let response = try JSONDecoder().decode(GalleryUploadResponse.self, from: data)
        XCTAssertFalse(GoogleDriveGalleryUploadService.isAuthenticationFailure(response))
    }

    func testOperatorFacingAuthMessagePointsToGallerySetup() {
        XCTAssertEqual(
            GalleryUploadError.unauthorized.localizedDescription,
            "Gallery authentication failed. Re-enter the device upload token in Gallery Setup."
        )
    }
}

/// Production durability: fail-closed pre-print checkpoint, durable archive commit, Wi-Fi
/// transmission-state propagation and the explicit Bluetooth production policy.
@MainActor
final class PrintDurabilityTests: XCTestCase {
    private var directory: URL!
    private var auditURL: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("durability-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        auditURL = directory.appendingPathComponent("audit.json")
    }

    override func tearDownWithError() throws {
        if let directory {
            makeWritable(directory)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    // MARK: Fail-closed pre-print checkpoint

    func testSuccessfulCheckpointPermitsPrintAndPersistsUnknownStatus() async throws {
        let recovery = try AppRecoveryStore(directoryURL: directory.appendingPathComponent("recovery"))
        let spooler = try makeSpooler()
        let fake = DeterministicFakePrinterTransport(scenario: .immediateSuccess)
        var checkpointCount = 0

        let result = await spooler.submit(
            envelope: try ReliabilityFixtures.envelope(seed: 1),
            prePrintCheckpoint: { _ in
                checkpointCount += 1
                try recovery.saveCritical(self.snapshot(stage: .printStatusUnknown))
            },
            transport: fake.operation
        )

        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(checkpointCount, 1)
        XCTAssertEqual(fake.records.count, 1)
        XCTAssertEqual(recovery.load()?.stage, .printStatusUnknown, "Checkpoint is on disk before bytes")
    }

    func testFailedCheckpointNeverInvokesTransportAndSendsZeroBytes() async throws {
        let recoveryDirectory = directory.appendingPathComponent("readonly-recovery")
        let recovery = try AppRecoveryStore(directoryURL: recoveryDirectory)
        makeReadOnly(recoveryDirectory)
        // Real storage failure, not a mock: the directory cannot accept the checkpoint file.
        XCTAssertThrowsError(try recovery.saveCritical(snapshot(stage: .printStatusUnknown)))

        let spooler = try makeSpooler()
        let fake = DeterministicFakePrinterTransport(scenario: .immediateSuccess)
        let result = await spooler.submit(
            envelope: try ReliabilityFixtures.envelope(seed: 2),
            prePrintCheckpoint: { _ in
                do {
                    try recovery.saveCritical(self.snapshot(stage: .printStatusUnknown))
                } catch {
                    throw PrintCheckpointError.persistenceFailed(error.localizedDescription)
                }
            },
            transport: fake.operation
        )

        guard case .failure(let error) = result else { return XCTFail("Print must be blocked") }
        XCTAssertTrue(error is PrintCheckpointError)
        XCTAssertTrue(fake.records.isEmpty, "Transport is never invoked")
        XCTAssertEqual(fake.records.reduce(0) { $0 + ($1.bytesStarted ? $1.payloadByteCount : 0) }, 0, "Zero bytes sent")
        XCTAssertFalse(spooler.requiresRecovery, "No bytes means no recovery lock")
        XCTAssertFalse(spooler.isWorking, "Queue accounting is released")
        let audit = try XCTUnwrap(try PrintAuditStore(fileURL: auditURL).load().last)
        XCTAssertEqual(audit.terminalResult, .failedBeforeBytes)
        XCTAssertFalse(audit.bytesStarted)

        // Storage recovers: the same session can print on retry.
        makeWritable(recoveryDirectory)
        let retry = await spooler.submit(
            envelope: try ReliabilityFixtures.envelope(seed: 2),
            prePrintCheckpoint: { _ in try recovery.saveCritical(self.snapshot(stage: .printStatusUnknown)) },
            transport: fake.operation
        )
        XCTAssertTrue(retry.isSuccess)
        XCTAssertEqual(fake.records.count, 1)
    }

    func testCheckpointRunsBeforeEveryCopyAndBlocksOnlyTheFailingCopy() async throws {
        let spooler = try makeSpooler()
        let fake = DeterministicFakePrinterTransport(scenario: .immediateSuccess)
        let batch = UUID()
        var checkpoints: [Int] = []
        var results: [Bool] = []
        for copy in 1...3 {
            let result = await spooler.submit(
                envelope: try ReliabilityFixtures.envelope(seed: 9, batchID: batch, copyIndex: copy, copyCount: 3),
                prePrintCheckpoint: { envelope in
                    checkpoints.append(envelope.copyIndex)
                    if envelope.copyIndex == 2 { throw PrintCheckpointError.persistenceFailed("disk full") }
                },
                transport: fake.operation
            )
            results.append(result.isSuccess)
        }
        XCTAssertEqual(checkpoints, [1, 2, 3])
        XCTAssertEqual(results, [true, false, true])
        XCTAssertEqual(fake.records.map(\.copyIndex), [1, 3], "Copy 2 never reached the printer")
        XCTAssertEqual(fake.maximumConcurrentPhysicalJobs, 1, "Spooler stays serialized")
    }

    func testCriticalRecoverySaveIsVerifiedAndLeavesNoTemporaryFiles() throws {
        let recoveryDirectory = directory.appendingPathComponent("recovery-verify")
        let recovery = try AppRecoveryStore(directoryURL: recoveryDirectory)
        try recovery.saveCritical(snapshot(stage: .receiptComposed))
        try recovery.saveCritical(snapshot(stage: .printStatusUnknown))
        XCTAssertEqual(recovery.load()?.stage, .printStatusUnknown)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: recoveryDirectory.path).filter { $0.hasSuffix(".tmp") }
        XCTAssertTrue(leftovers.isEmpty)

        // A failed critical write leaves the previous complete checkpoint intact.
        makeReadOnly(recoveryDirectory)
        XCTAssertThrowsError(try recovery.saveCritical(snapshot(stage: .receiptComposed)))
        XCTAssertEqual(recovery.load()?.stage, .printStatusUnknown)
        makeWritable(recoveryDirectory)
    }

    // MARK: Durable archive

    func testArchivePayloadCommitsDurablyBeforeThumbnailsAndIsIdempotent() throws {
        let store = try RecentSessionArchiveStore(directoryURL: directory.appendingPathComponent("archive"))
        let payload = try archivePayload(token: String(repeating: "a", count: 64), seed: 11)

        try SessionArchiveCommitter.commitPrintPayload(payload, store: store)
        let committed = try store.load(archiveID: payload.committedSession.galleryToken)
        XCTAssertEqual(committed.rasterizedImage.rasterCommand, payload.rasterizedImage.rasterCommand, "Reprint record exists without thumbnails")
        XCTAssertTrue(committed.thumbnailData.isEmpty)
        XCTAssertTrue(store.containsCommittedArchive(galleryToken: payload.committedSession.galleryToken))

        SessionArchiveCommitter.attachThumbnails(for: payload.committedSession, store: store)
        let withThumbnails = try store.load(archiveID: payload.committedSession.galleryToken)
        XCTAssertEqual(withThumbnails.thumbnailData.count, payload.committedSession.photos.count)
        XCTAssertEqual(withThumbnails.rasterizedImage.rasterCommand, payload.rasterizedImage.rasterCommand)

        // Re-committing (e.g. retry at print time) and re-attaching are harmless.
        XCTAssertNoThrow(try SessionArchiveCommitter.commitPrintPayload(payload, store: store))
        SessionArchiveCommitter.attachThumbnails(for: payload.committedSession, store: store)
        XCTAssertEqual(try store.load(archiveID: payload.committedSession.galleryToken).thumbnailData.count, payload.committedSession.photos.count)
    }

    func testArchiveCommitFailureIsReportedAndNeverPartiallyVisible() throws {
        let archiveDirectory = directory.appendingPathComponent("archive-readonly")
        let store = try RecentSessionArchiveStore(directoryURL: archiveDirectory)
        makeReadOnly(archiveDirectory)
        let payload = try archivePayload(token: String(repeating: "b", count: 64), seed: 12)
        XCTAssertThrowsError(try SessionArchiveCommitter.commitPrintPayload(payload, store: store))
        makeWritable(archiveDirectory)
        XCTAssertFalse(store.containsCommittedArchive(galleryToken: payload.committedSession.galleryToken))
        XCTAssertTrue(try store.summaries().isEmpty, "No half-written archive is listed")
    }

    func testArchivesNeverCrossContaminateBetweenSessions() throws {
        let store = try RecentSessionArchiveStore(directoryURL: directory.appendingPathComponent("archive-multi"))
        let first = try archivePayload(token: String(repeating: "c", count: 64), seed: 21)
        let second = try archivePayload(token: String(repeating: "d", count: 64), seed: 22)
        try SessionArchiveCommitter.commitPrintPayload(first, store: store)
        try SessionArchiveCommitter.commitPrintPayload(second, store: store)
        XCTAssertEqual(try store.load(archiveID: first.committedSession.galleryToken).rasterizedImage.rasterCommand, first.rasterizedImage.rasterCommand)
        XCTAssertEqual(try store.load(archiveID: second.committedSession.galleryToken).rasterizedImage.rasterCommand, second.rasterizedImage.rasterCommand)

        // A different receipt claiming an existing session identity is rejected, not merged.
        let impostor = try archivePayload(token: first.committedSession.galleryToken, seed: 99)
        XCTAssertThrowsError(try SessionArchiveCommitter.commitPrintPayload(impostor, store: store)) { error in
            XCTAssertEqual(error as? RecentSessionArchiveError, .conflictingArchive)
        }
        XCTAssertEqual(try store.load(archiveID: first.committedSession.galleryToken).rasterizedImage.rasterCommand, first.rasterizedImage.rasterCommand)
    }

    func testRecoveryClearIsScopedToItsOwnSession() throws {
        let recovery = try AppRecoveryStore(directoryURL: directory.appendingPathComponent("recovery-scope"))
        try recovery.saveCritical(snapshot(stage: .printStatusUnknown, session: "PP-SESSION-A"))
        recovery.clear(sessionIdentifier: "PP-SESSION-B")
        XCTAssertEqual(recovery.load()?.sessionIdentifier, "PP-SESSION-A", "Another session can never clear A's recovery record")
        recovery.clear(sessionIdentifier: "PP-SESSION-A")
        XCTAssertNil(recovery.load())
    }

    // MARK: Wi-Fi transmission state

    func testWifiOutcomeMappingForEveryTransmissionState() {
        let failure = PrinterNetworkError.connectionFailed("refused")
        for (state, expectedBytes) in [(NetworkPrintTransmission.notConnected, false), (.connectedBeforeSend, false), (.sendStarted, true)] {
            guard case .failure(let error) = PrinterCoordinator.wifiTransportOutcome(result: .failure(failure), transmission: state) else {
                return XCTFail("\(state) failure must stay a failure")
            }
            let transportFailure = error as? PrintTransportFailure
            XCTAssertEqual(transportFailure?.bytesStarted, expectedBytes, "\(state)")
            XCTAssertEqual(transportFailure?.transportResult?.transport, .wifi)
        }
        guard case .success(let success) = PrinterCoordinator.wifiTransportOutcome(result: .success(()), transmission: .sendCompleted) else {
            return XCTFail("Completed send succeeds")
        }
        XCTAssertTrue(success.bytesStarted)
        XCTAssertFalse(NetworkPrintTransmission.notConnected.bytesMayHaveStarted)
        XCTAssertFalse(NetworkPrintTransmission.connectedBeforeSend.bytesMayHaveStarted)
        XCTAssertTrue(NetworkPrintTransmission.sendStarted.bytesMayHaveStarted)
        XCTAssertTrue(NetworkPrintTransmission.sendCompleted.bytesMayHaveStarted)
    }

    func testWifiFailureBeforeBytesDoesNotLockRecovery() async throws {
        for state in [NetworkPrintTransmission.notConnected, .connectedBeforeSend] {
            let spooler = try makeSpooler()
            var attempts = 0
            let result = await spooler.submit(envelope: try ReliabilityFixtures.envelope(seed: 31)) { _ in
                attempts += 1
                return PrinterCoordinator.wifiTransportOutcome(result: .failure(.timedOut(host: "printer", port: 9100)), transmission: state)
            }
            XCTAssertTrue(result.isFailure)
            XCTAssertFalse(spooler.requiresRecovery, "\(state) is a safe failure")
            XCTAssertEqual(attempts, 1)
            XCTAssertEqual(try PrintAuditStore(fileURL: auditURL).load().last?.terminalResult, .failedBeforeBytes)
        }
    }

    func testWifiFailureAfterBytesRequiresRecoveryAndNeverRetries() async throws {
        let spooler = try makeSpooler()
        var attempts = 0
        let result = await spooler.submit(envelope: try ReliabilityFixtures.envelope(seed: 32)) { _ in
            attempts += 1
            return PrinterCoordinator.wifiTransportOutcome(result: .failure(.sendFailed("reset by peer")), transmission: .sendStarted)
        }
        XCTAssertTrue(result.isFailure)
        XCTAssertTrue(spooler.requiresRecovery)
        XCTAssertEqual(attempts, 1, "No automatic retry after bytes may have started")
        XCTAssertEqual(try PrintAuditStore(fileURL: auditURL).load().last?.terminalResult, .recoveryRequiredAfterBytes)

        // Locked: the next job is refused without touching the transport.
        let next = await spooler.submit(envelope: try ReliabilityFixtures.envelope(seed: 33)) { _ in
            attempts += 1
            return .failure(PrinterNetworkError.jobAlreadyActive)
        }
        XCTAssertTrue(next.isFailure)
        XCTAssertEqual(attempts, 1)
    }

    // MARK: Bluetooth production policy

    func testBluetoothProductionPolicyIsExplicitAndSafeModeRemainsAvailable() {
        XCTAssertEqual(ProductionReceiptTransportDecision.defaultMode, .balanced)
        XCTAssertEqual(ProductionReceiptTransportDecision.defaultMode.transportPolicy, .experimentalBalanced, "Balanced stays labelled experimental until hardware qualification")
        XCTAssertEqual(ProductionReceiptTransportDecision.safeFallbackMode.transportPolicy, .safeIntegrity)
        XCTAssertTrue(ReceiptBluetoothTransferMode.allCases.contains(.compatibility))
        XCTAssertTrue(ReceiptBluetoothTransferMode.balanced.operatorSummary.contains("Experimental Balanced"))
        XCTAssertTrue(ReceiptBluetoothTransferMode.compatibility.operatorSummary.contains("Safe / Integrity"))
    }

    // MARK: Helpers

    private func makeSpooler() throws -> PrintSpooler {
        PrintSpooler(auditStore: try PrintAuditStore(fileURL: auditURL), waitsForPhysicalHandoff: false, writesAuditSynchronously: true)
    }

    nonisolated private func snapshot(stage: AppRecoveryStage, session: String = "PP-DURABLE-1") -> AppRecoverySnapshot {
        AppRecoverySnapshot(
            schemaVersion: AppRecoverySnapshot.schemaVersion,
            sessionIdentifier: session,
            createdAt: Date(timeIntervalSince1970: 1_793_000_000),
            format: .solo,
            eventProfile: nil,
            galleryToken: String(repeating: "f", count: 64),
            galleryURL: nil,
            photoJPEGData: [],
            receiptPreviewPNGData: nil,
            thermalPreviewPNGData: nil,
            rasterFingerprint: "ABC123",
            stage: stage,
            updatedAt: Date()
        )
    }

    private func archivePayload(token: String, seed: Int) throws -> RecentSessionArchivePayload {
        let photos = [ReliabilityFixtures.syntheticPhoto(session: seed, photo: 1, format: .duo), ReliabilityFixtures.syntheticPhoto(session: seed, photo: 2, format: .duo)]
        let session = CommittedGallerySession(
            sessionIdentifier: "PP-ARCHIVE-\(seed)",
            createdAt: Date(timeIntervalSince1970: 1_793_000_000 + Double(seed)),
            galleryToken: token,
            galleryURL: URL(string: "https://example.com/?g=\(token)")!,
            photos: photos,
            format: .duo,
            eventProfile: nil
        )
        let receipt = try ReceiptComposer.compose(photos: photos, sessionIdentifier: session.sessionIdentifier, date: session.createdAt, galleryURL: session.galleryURL, format: .duo)
        let raster = try ThermalImageRasterizer.rasterize(XCTUnwrap(UIImage(data: receipt.imagePNGData)), purpose: .completeReceipt)
        return RecentSessionArchivePayload(committedSession: session, composedReceipt: receipt, receiptPreviewPNGData: receipt.imagePNGData, thermalPreviewPNGData: raster.previewPNGData, rasterizedImage: raster, photoThumbnailData: [])
    }

    private func makeReadOnly(_ url: URL) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: url.path)
    }

    private func makeWritable(_ url: URL) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
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
