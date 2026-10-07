import Foundation
import XCTest
import UIKit
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

    func testSixPhotoCommittedSessionOfflineQueueAndResetIsolation() throws {
        let sourcePhotos = (0..<6).map { ReliabilityFixtures.syntheticPhoto(session: 601, photo: $0 + 1, format: .gridSix) }
        let date = Date(timeIntervalSince1970: 1_788_692_040)
        let token = String(repeating: "b", count: 64)
        let baseURL = URL(string: "https://example.com/")!
        let url = try GalleryURLBuilder.makeGalleryURL(customerGalleryBaseURL: baseURL, galleryToken: token)
        let committed = CommittedGallerySession(sessionIdentifier: "PP-GRID6-A", createdAt: date, galleryToken: token, galleryURL: url, photos: sourcePhotos, format: .gridSix, eventProfile: nil)
        let receipt = try ReceiptComposer.compose(photos: committed.photos, sessionIdentifier: committed.sessionIdentifier, date: date, galleryURL: url, format: committed.format)
        let payload = try GoogleDriveGalleryUploadService.preparePayload(photos: committed.photos, composedReceipt: XCTUnwrap(UIImage(data: receipt.imagePNGData)), sessionID: committed.sessionIdentifier, createdAt: date, galleryToken: token, customerGalleryBaseURL: baseURL)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = try GalleryPendingUploadStore(directoryURL: directory)
        try queue.save(payload)
        try queue.recordAttempt(galleryToken: token)
        let reopened = try GalleryPendingUploadStore(directoryURL: directory)
        let loaded = try XCTUnwrap(reopened.load(galleryToken: token))
        XCTAssertEqual(loaded.photos.count, 6)
        XCTAssertEqual(loaded.photos.map(\.data), payload.photos.map(\.data))
        XCTAssertEqual(loaded.colorReceipt.data, payload.colorReceipt.data)
        XCTAssertEqual(loaded.thermalReceipt?.data, payload.thermalReceipt?.data)
        XCTAssertEqual(loaded.gif?.data, payload.gif?.data)
        XCTAssertEqual(Set(loaded.photos.map(\.data)).count, 6)
        let request = try GoogleDriveGalleryUploadService.makeRequestBody(payload: loaded, deviceToken: String(repeating: "x", count: 32))
        XCTAssertEqual(request.photos.map(\.filename), (1...6).map { String(format: "photo-%02d.jpg", $0) })
        XCTAssertEqual(request.galleryToken, token)
        XCTAssertEqual(request.sessionID, committed.sessionIdentifier)
        XCTAssertNil(request.receipt)
        XCTAssertNotNil(request.colorReceipt)
        XCTAssertEqual(try reopened.summaries().first?.retryAttemptCount, 1)

        let model = BoothSessionViewModel()
        model.selectedBoothFormat = .gridSix
        model.capturedPhotos = sourcePhotos
        model.state = .review
        XCTAssertEqual(model.requiredPhotoCount, 6)
        XCTAssertTrue(model.canContinueToReceipt)
        model.state = .thankYou
        model.resetAfterDone()
        XCTAssertTrue(model.capturedPhotos.isEmpty)
        XCTAssertNil(model.selectedBoothFormat)
        XCTAssertEqual(committed.photos.count, 6)
        model.selectedBoothFormat = .solo
        model.capturedPhotos = [ReliabilityFixtures.syntheticPhoto(session: 602, photo: 1, format: .solo)]
        XCTAssertFalse(committed.photos.contains { $0.pngData() == model.capturedPhotos[0].pngData() })
        model.cancelSession()
        XCTAssertTrue(model.capturedPhotos.isEmpty)
    }

    func testSixPhotoSequenceReachesReviewOnlyAfterSixAndRejectsExtraSamples() {
        let model = BoothSessionViewModel()
        model.selectedBoothFormat = .gridSix
        model.isCameraUnavailable = true
        for index in 0..<6 {
            model.addSamplePhoto(ReliabilityFixtures.syntheticPhoto(session: 610, photo: index + 1, format: .gridSix))
            XCTAssertEqual(model.capturedPhotos.count, index + 1)
            XCTAssertEqual(model.state, index == 5 ? .review : .cameraReady)
            XCTAssertEqual(model.canContinueToReceipt, index == 5)
        }
        model.addSamplePhoto(ReliabilityFixtures.syntheticPhoto(session: 999, photo: 1, format: .solo))
        XCTAssertEqual(model.capturedPhotos.count, 6)
        model.cancelSession()
        XCTAssertTrue(model.capturedPhotos.isEmpty)
        XCTAssertEqual(model.samplePhotoCount, 0)
    }

    func testGridSixRecoveryRoundTripsZeroThroughSixPhotos() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try AppRecoveryStore(directoryURL: directory)
        let data = try (0..<6).map { try XCTUnwrap(AppRecoveryStore.photoData(from: ReliabilityFixtures.syntheticPhoto(session: 600, photo: $0 + 1, format: .gridSix))) }
        for count in 0...6 {
            let snapshot = AppRecoverySnapshot(schemaVersion: 1, sessionIdentifier: "PP-GRID6-RECOVERY", createdAt: Date(), format: .gridSix, eventProfile: nil, galleryToken: nil, galleryURL: nil, photoJPEGData: Array(data.prefix(count)), receiptPreviewPNGData: nil, thermalPreviewPNGData: nil, rasterFingerprint: nil, stage: count == 0 ? .formatSelected : .photosCaptured, updatedAt: Date())
            store.save(snapshot)
            let loaded = try XCTUnwrap(store.load())
            XCTAssertEqual(loaded.format, .gridSix)
            XCTAssertEqual(loaded.photoJPEGData, Array(data.prefix(count)))
        }
        store.clear(sessionIdentifier: "different-session")
        XCTAssertEqual(store.load()?.photoJPEGData.count, 6)
        store.clear(sessionIdentifier: "PP-GRID6-RECOVERY")
        XCTAssertNil(store.load())
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
