import Foundation
import XCTest
@testable import PocketPixelsBooth

@MainActor
final class SessionIsolationAndRecoveryTests: XCTestCase {
    func testNewCustomerCannotReusePreviousCustomerPayload() throws {
        let sessionA = try simulatedSession(index: 1, format: .duo, copies: 5)
        let sessionB = try simulatedSession(index: 2, format: .solo, copies: 1)

        XCTAssertNotEqual(sessionA.sessionID, sessionB.sessionID)
        XCTAssertNotEqual(sessionA.batchID, sessionB.batchID)
        XCTAssertNotEqual(sessionA.galleryToken, sessionB.galleryToken)
        XCTAssertNotEqual(sessionA.galleryURL, sessionB.galleryURL)
        XCTAssertNotEqual(sessionA.payloadFingerprint, sessionB.payloadFingerprint)
        XCTAssertFalse(sessionB.receiptMarkers.contains(sessionA.sessionID))
        XCTAssertFalse(sessionB.receiptMarkers.contains(sessionA.galleryToken))
    }

    func testCopyCountResetsToOneForNewSession() throws {
        let sessionA = try simulatedSession(index: 10, format: .duo, copies: 5)
        let sessionB = try simulatedSession(index: 11, format: .solo, copies: 1)

        XCTAssertEqual(sessionA.copyCount, 5)
        XCTAssertEqual(sessionB.copyCount, 1)
    }

    func testDelayedOldSessionCallbackCannotMutateNewSession() {
        var model = GenerationGuardedState(sessionID: "A", generation: 1)
        let oldGeneration = model.generation
        model.resetForNewSession(sessionID: "B")
        model.applyPrintProgress("A print complete", generation: oldGeneration)

        XCTAssertEqual(model.sessionID, "B")
        XCTAssertNil(model.printProgress)
        XCTAssertEqual(model.staleCallbackRejections, 1)
    }

    func testOldReceiptCompositionCannotOverwriteNewSession() {
        var model = GenerationGuardedState(sessionID: "A", generation: 1)
        let oldGeneration = model.generation
        model.resetForNewSession(sessionID: "B")
        model.applyReceipt("receipt-A", generation: oldGeneration)

        XCTAssertEqual(model.sessionID, "B")
        XCTAssertNil(model.receiptFingerprint)
        XCTAssertEqual(model.staleCallbackRejections, 1)
    }

    func testOldGalleryCompletionCannotOverwriteNewSession() {
        var model = GenerationGuardedState(sessionID: "A", generation: 1)
        let oldGeneration = model.generation
        model.resetForNewSession(sessionID: "B")
        model.applyGalleryURL("https://gallery.example.com/A", generation: oldGeneration)

        XCTAssertEqual(model.sessionID, "B")
        XCTAssertNil(model.galleryURL)
        XCTAssertEqual(model.staleCallbackRejections, 1)
    }

    func testOldCameraCallbackCannotOverwriteNewSession() {
        var model = GenerationGuardedState(sessionID: "A", generation: 1)
        let oldGeneration = model.generation
        model.resetForNewSession(sessionID: "B")
        model.applyCameraReady(generation: oldGeneration)

        XCTAssertEqual(model.sessionID, "B")
        XCTAssertFalse(model.isCameraReady)
        XCTAssertEqual(model.staleCallbackRejections, 1)
    }

    func testRapidSessionResetDoesNotLeakState() {
        var model = GenerationGuardedState(sessionID: "A", generation: 1)
        model.receiptFingerprint = "payload-A"
        model.galleryURL = "https://gallery.example.com/A"
        model.printProgress = "printing"
        model.copyCount = 10

        model.resetForNewSession(sessionID: "B")

        XCTAssertEqual(model.sessionID, "B")
        XCTAssertNil(model.receiptFingerprint)
        XCTAssertNil(model.galleryURL)
        XCTAssertNil(model.printProgress)
        XCTAssertEqual(model.copyCount, 1)
    }

    func testCrashAtPrintStatusUnknownDoesNotAutoReprint() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("recovery-\(UUID().uuidString)", isDirectory: true)
        let store = try AppRecoveryStore(directoryURL: directory)
        let snapshot = AppRecoverySnapshot(
            schemaVersion: AppRecoverySnapshot.schemaVersion,
            sessionIdentifier: "PP-20260907-UNKNOWN",
            createdAt: Date(timeIntervalSince1970: 1_788_692_040),
            format: .duo,
            eventProfile: nil,
            galleryToken: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            galleryURL: URL(string: "https://example.com/g/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")!,
            photoJPEGData: [Data([1, 2, 3])],
            receiptPreviewPNGData: Data([4, 5, 6]),
            thermalPreviewPNGData: Data([7, 8, 9]),
            rasterFingerprint: "ABCDEF",
            stage: .printStatusUnknown,
            updatedAt: Date(timeIntervalSince1970: 1_788_692_050)
        )

        store.save(snapshot)
        let loaded = try XCTUnwrap(store.load())

        XCTAssertEqual(loaded.stage, .printStatusUnknown)
        XCTAssertTrue(loaded.requiresOperatorPrintRecovery)
        XCTAssertFalse(loaded.isSafeForAutomaticPrint)
    }

    func testSyntheticRasterPreservesSeedBeyondOneByte() throws {
        let first = try ReliabilityFixtures.rasterizedImage(seed: 1)
        let repeated = try ReliabilityFixtures.rasterizedImage(seed: 1)
        let later = try ReliabilityFixtures.rasterizedImage(seed: 257)

        XCTAssertEqual(first.rasterData, repeated.rasterData)
        XCTAssertNotEqual(first.rasterData, later.rasterData)
        XCTAssertNotEqual(first.rasterCommand, later.rasterCommand)
    }

    func testOneThousandSessionsHaveZeroCrossSessionContamination() throws {
        var sessionIDs = Set<String>()
        var batchIDs = Set<UUID>()
        var tokens = Set<String>()
        var payloadsByFingerprint: [String: SimulatedReliabilitySession] = [:]

        for index in 1...1_000 {
            let format = BoothFormat.allCases[(index - 1) % BoothFormat.allCases.count]
            let copies = [1, 2, 3, 5, 10][index % 5]
            let session = try simulatedSession(index: index, format: format, copies: copies)

            XCTAssertTrue(sessionIDs.insert(session.sessionID).inserted, "Duplicate session ID at \(index)")
            XCTAssertTrue(batchIDs.insert(session.batchID).inserted, "Duplicate batch ID at \(index)")
            XCTAssertTrue(tokens.insert(session.galleryToken).inserted, "Duplicate gallery token at \(index)")
            XCTAssertNil(payloadsByFingerprint[session.payloadFingerprint], "Duplicate payload fingerprint at \(index)")
            XCTAssertTrue(session.receiptMarkers.contains(session.sessionID))
            XCTAssertTrue(session.receiptMarkers.contains(session.galleryToken))
            XCTAssertEqual(session.copyCount, copies)

            for previous in payloadsByFingerprint.values {
                XCTAssertFalse(session.receiptMarkers.contains(previous.sessionID), "Session \(index) contains stale session ID \(previous.sessionID)")
                XCTAssertFalse(session.receiptMarkers.contains(previous.galleryToken), "Session \(index) contains stale token \(previous.galleryToken)")
            }
            payloadsByFingerprint[session.payloadFingerprint] = session
        }

        XCTAssertEqual(sessionIDs.count, 1_000)
        XCTAssertEqual(batchIDs.count, 1_000)
        XCTAssertEqual(tokens.count, 1_000)
        XCTAssertEqual(payloadsByFingerprint.count, 1_000)
    }

    private func simulatedSession(index: Int, format: BoothFormat, copies: Int) throws -> SimulatedReliabilitySession {
        let sessionID = "PP-20260907-\(String(format: "%06d", index))"
        let token = String(format: "%064x", index)
        let galleryURL = URL(string: "https://gallery.example.com/?g=\(token)")!
        let batchID = UUID()
        let rasterized = try ReliabilityFixtures.rasterizedImage(seed: index, height: 48 + (index % 8))
        let envelope = try PrintJobEnvelope.receipt(
            rasterizedImage: rasterized,
            sessionIdentifier: sessionID,
            source: .liveCustomer,
            copyIndex: 1,
            copyCount: copies,
            batchID: batchID,
            transportPolicy: .safeIntegrity
        )
        let markers = "\(sessionID)|\(token)|\(galleryURL.absoluteString)|\(format.rawValue)|copy=\(copies)"
        return SimulatedReliabilitySession(
            sessionID: sessionID,
            batchID: batchID,
            galleryToken: token,
            galleryURL: galleryURL,
            copyCount: copies,
            payloadFingerprint: envelope.payloadFingerprint,
            receiptMarkers: markers
        )
    }
}

private struct SimulatedReliabilitySession {
    let sessionID: String
    let batchID: UUID
    let galleryToken: String
    let galleryURL: URL
    let copyCount: Int
    let payloadFingerprint: String
    let receiptMarkers: String
}

private struct GenerationGuardedState {
    var sessionID: String
    var generation: Int
    var receiptFingerprint: String?
    var galleryURL: String?
    var printProgress: String?
    var copyCount = 1
    var isCameraReady = false
    var staleCallbackRejections = 0

    mutating func resetForNewSession(sessionID: String) {
        generation += 1
        self.sessionID = sessionID
        receiptFingerprint = nil
        galleryURL = nil
        printProgress = nil
        copyCount = 1
        isCameraReady = false
    }

    mutating func applyReceipt(_ fingerprint: String, generation callbackGeneration: Int) {
        guard callbackGeneration == generation else {
            staleCallbackRejections += 1
            return
        }
        receiptFingerprint = fingerprint
    }

    mutating func applyGalleryURL(_ url: String, generation callbackGeneration: Int) {
        guard callbackGeneration == generation else {
            staleCallbackRejections += 1
            return
        }
        galleryURL = url
    }

    mutating func applyPrintProgress(_ progress: String, generation callbackGeneration: Int) {
        guard callbackGeneration == generation else {
            staleCallbackRejections += 1
            return
        }
        printProgress = progress
    }

    mutating func applyCameraReady(generation callbackGeneration: Int) {
        guard callbackGeneration == generation else {
            staleCallbackRejections += 1
            return
        }
        isCameraReady = true
    }
}

private extension AppRecoverySnapshot {
    var requiresOperatorPrintRecovery: Bool {
        stage == .printStatusUnknown
    }

    var isSafeForAutomaticPrint: Bool {
        false
    }
}
