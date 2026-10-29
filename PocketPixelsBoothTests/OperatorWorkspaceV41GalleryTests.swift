import Combine
import XCTest
import UIKit
@testable import PocketPixelsBooth

@MainActor final class OperatorWorkspaceV41GalleryTests: XCTestCase {
    private var root: URL!
    private let token = String(repeating: "d", count: 64)
    private let sessionID = "PP-20261025-120000"
    private var url: URL { URL(string: "https://gallery-fixture.example.test/?g=\(token)")! }
    private var target: GalleryVerificationTarget { .init(sessionID: sessionID, token: token, url: url, photoCount: 1, schemaVersion: 2, fileCount: 4) }
    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("v41-gallery-\(UUID())")
        V41GalleryProtocol.mode = .complete; V41GalleryProtocol.methods = []
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }
    private func network() -> URLSession {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [V41GalleryProtocol.self]
        return URLSession(configuration: config)
    }
    private func payload() throws -> GalleryPreparedUploadPayload {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 48)).image { _ in }
        return try GoogleDriveGalleryUploadService.preparePayload(photos: [image], composedReceipt: image, sessionID: sessionID,
            createdAt: Date(), galleryToken: token, customerGalleryBaseURL: URL(string: "https://gallery-fixture.example.test")!)
    }
    func testRegularBoothVerificationSurvivesRelaunchWithoutEventRecord() async throws {
        let store = try GalleryVerificationStore(directory: root)
        let source = try await GalleryPublicVerifier.verify(target, session: network())
        try store.record(sessionID: sessionID, token: token, url: url, source: source)
        let reopened = try GalleryVerificationStore(directory: root)
        XCTAssertNotNil(try reopened.evidence(sessionID: sessionID, token: token, url: url))
        XCTAssertNil(try reopened.evidence(sessionID: sessionID + "other", token: token, url: url))
        XCTAssertNil(try reopened.evidence(sessionID: sessionID, token: token, url: URL(string: "https://other.example.test/?g=\(token)")!))
        XCTAssertFalse(String(data: try Data(contentsOf: FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)[0]), encoding: .utf8)!.contains(token))
    }
    func testEventCallbackAndIndependentEvidenceBothPersist() async throws {
        let queue = try GalleryPendingUploadStore(directoryURL: root.appendingPathComponent("queue")); try queue.save(payload())
        let evidence = try GalleryVerificationStore(directory: root.appendingPathComponent("evidence"))
        let runs = EventRunStore(directory: root.appendingPathComponent("runs"), authorized: { true }, blockingReason: { nil })
        let run = try runs.startNewRun(context: .init(designID: nil, commercialEventID: nil, serverBinding: nil, name: "Synthetic Event"))
        try runs.beginSession(id: sessionID, runID: run.id, format: "solo")
        let service = GoogleDriveGalleryUploadService(configurationProvider: { try GoogleDriveGalleryConfiguration.validate(rawValue: "https://script.google.com/macros/s/TEST/exec") },
            urlSession: network(), pendingStore: queue, verificationStore: evidence,
            onPublicGalleryVerified: { id in runs.updateSession(id: id) { $0.galleryVerifiedAt = Date() } })
        _ = try await service.uploadPendingGallery(galleryToken: token, deviceToken: String(repeating: "x", count: 32))
        XCTAssertNotNil(try runs.session(id: sessionID)?.galleryVerifiedAt)
        XCTAssertNotNil(try evidence.evidence(sessionID: sessionID, token: token, url: url))
        XCTAssertNil(try queue.load(galleryToken: token))
    }
    func testWrongTokenSessionManifestAndIncompleteResponsesAreRejected() async throws {
        for mode in [V41GalleryMode.wrongToken, .wrongSession, .wrongCount, .wrongSchema, .incomplete, .empty200, .notFound] {
            V41GalleryProtocol.mode = mode
            do { _ = try await GalleryPublicVerifier.verify(target, session: network()); XCTFail("\(mode) must not verify") }
            catch { }
        }
    }
    func testOfflineIsNotProofOfGalleryUnavailability() async throws {
        V41GalleryProtocol.mode = .offline
        do { _ = try await GalleryPublicVerifier.verify(target, session: network()); XCTFail() }
        catch { XCTAssertTrue(error is URLError) }
        XCTAssertEqual(ArchivedGalleryStatus.resolve(linkIsValid: true, pendingItem: nil, verifiedAt: nil), .unknown)
    }
    func testInvalidFrozenLinkNeverRequestsNetwork() async throws {
        let invalid = GalleryVerificationTarget(sessionID: sessionID, token: token, url: URL(string: "https://example.test/?g=wrong")!, photoCount: 1)
        do { _ = try await GalleryPublicVerifier.verify(invalid, session: network()); XCTFail() } catch { }
        XCTAssertTrue(V41GalleryProtocol.methods.isEmpty)
    }
    func testLegacyRequiresExistingCompletionEvidence() async throws {
        V41GalleryProtocol.mode = .legacy
        let source = try await GalleryPublicVerifier.verify(target, session: network())
        XCTAssertEqual(source, "legacy-complete-page")
        V41GalleryProtocol.mode = .empty200
        do { _ = try await GalleryPublicVerifier.verify(target, session: network()); XCTFail() } catch { }
    }
    func testHistoricalReadinessStillRequiresSchemaMandatoryAssets() async throws {
        V41GalleryProtocol.mode = .wrongCount
        let historical = GalleryVerificationTarget(sessionID: sessionID, token: token, url: url, photoCount: 1)
        do { _ = try await GalleryPublicVerifier.verify(historical, session: network()); XCTFail("Schema 2 cannot omit its mandatory thermal receipt") }
        catch GalleryUploadError.deliveryUnknown { }
    }

    func testAuthoritativeUnavailableRateLimitAndRedirectedIdentityRemainDistinct() async throws {
        V41GalleryProtocol.mode = .unavailable
        do { _ = try await GalleryPublicVerifier.verify(target, session: network()); XCTFail() }
        catch GalleryPublicVerificationError.unavailable { }
        V41GalleryProtocol.mode = .rateLimited
        do { _ = try await GalleryPublicVerifier.verify(target, session: network()); XCTFail() }
        catch GalleryPublicVerificationError.rateLimited { }
        V41GalleryProtocol.mode = .redirectedGallery
        do { _ = try await GalleryPublicVerifier.verify(target, session: network()); XCTFail("A different gallery cannot establish original delivery") }
        catch GalleryUploadError.deliveryUnknown { }
    }

    func testDuplicateConcurrentEvidenceWritesAreIdempotentAndProtectedByIdentity() async throws {
        let store = try GalleryVerificationStore(directory: root)
        let target = target
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<12 { group.addTask { try store.record(sessionID: target.sessionID, token: target.token, url: target.url, source: "test", now: Date(timeIntervalSince1970: 100)) } }
            try await group.waitForAll()
        }
        XCTAssertEqual(try store.evidence(sessionID: sessionID, token: token, url: url)?.verifiedAt, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).count, 1)
    }
    func testStorageFailureRetainsPayloadAndRetryDoesNotPostAgain() async throws {
        let queue = try GalleryPendingUploadStore(directoryURL: root.appendingPathComponent("queue")); try queue.save(payload())
        let bad = try GalleryVerificationStore(directory: root.appendingPathComponent("evidence"), writer: { _, _ in throw CocoaError(.fileWriteOutOfSpace) })
        var callbacks = 0
        func service(_ evidence: GalleryVerificationStore) -> GoogleDriveGalleryUploadService {
            GoogleDriveGalleryUploadService(configurationProvider: { try GoogleDriveGalleryConfiguration.validate(rawValue: "https://script.google.com/macros/s/TEST/exec") },
                urlSession: network(), pendingStore: queue, verificationStore: evidence, onPublicGalleryVerified: { _ in callbacks += 1 })
        }
        do { _ = try await service(bad).uploadPendingGallery(galleryToken: token, deviceToken: String(repeating: "x", count: 32)); XCTFail() } catch { }
        XCTAssertEqual(callbacks, 0)
        XCTAssertEqual(try queue.load(galleryToken: token)?.deliveryState, .posted)
        XCTAssertNil(try bad.evidence(sessionID: sessionID, token: token, url: url))
        V41GalleryProtocol.mode = .offline
        do { _ = try await service(bad).uploadPendingGallery(galleryToken: token, deviceToken: String(repeating: "x", count: 32)); XCTFail() } catch { }
        XCTAssertEqual(V41GalleryProtocol.methods.filter { $0 == "POST" }.count, 1)
        V41GalleryProtocol.mode = .complete
        let good = try GalleryVerificationStore(directory: root.appendingPathComponent("evidence"))
        _ = try await service(good).uploadPendingGallery(galleryToken: token, deviceToken: String(repeating: "x", count: 32))
        XCTAssertEqual(V41GalleryProtocol.methods.filter { $0 == "POST" }.count, 1)
        XCTAssertEqual(callbacks, 1)
        XCTAssertNil(try queue.load(galleryToken: token))
    }
    func testAmbiguousUploadReconciliationStorageFailureBecomesVerificationOnly() async throws {
        let queue = try GalleryPendingUploadStore(directoryURL: root.appendingPathComponent("queue")); try queue.save(payload())
        try queue.updateDeliveryState(.deliveryUnknown, galleryToken: token)
        let bad = try GalleryVerificationStore(directory: root.appendingPathComponent("evidence"), writer: { _, _ in throw CocoaError(.fileWriteOutOfSpace) })
        let service = GoogleDriveGalleryUploadService(urlSession: network(), pendingStore: queue, verificationStore: bad)
        do { _ = try await service.uploadPendingGallery(galleryToken: token, deviceToken: String(repeating: "x", count: 32)); XCTFail() } catch { }
        XCTAssertEqual(try queue.load(galleryToken: token)?.deliveryState, .posted)
        V41GalleryProtocol.mode = .offline
        do { _ = try await service.uploadPendingGallery(galleryToken: token, deviceToken: String(repeating: "x", count: 32)); XCTFail() } catch { }
        XCTAssertFalse(V41GalleryProtocol.methods.contains("POST"))
        XCTAssertNotNil(try queue.load(galleryToken: token))
    }

    func testMetadataIdentityChangeCannotReuseCachedProofForAnotherFrozenURL() async throws {
        let directory = root.appendingPathComponent("archive")
        let archive = try RecentSessionArchiveStore(directoryURL: directory)
        let payload = try V41ArchiveFixture.payload(token: token, sessionID: sessionID)
        try archive.save(payload)
        let evidence = try GalleryVerificationStore(directory: root.appendingPathComponent("evidence"))
        try evidence.record(sessionID: sessionID, token: token, url: payload.committedSession.galleryURL, source: "test")
        let model = RecentSessionsViewModel(store: archive, verificationStore: evidence)
        model.refresh()
        for _ in 0..<100 where model.summaries.first.map({ model.galleryStatus(for: $0) }) != .verified { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.summaries.first.map { model.galleryStatus(for: $0) }, .verified)
        let path = directory.appendingPathComponent(token).appendingPathComponent("metadata.json")
        var metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        metadata["galleryURL"] = "https://changed.example.test/?g=\(token)"
        try JSONSerialization.data(withJSONObject: metadata).write(to: path)
        model.refresh()
        while model.isLoading { try await Task.sleep(for: .milliseconds(10)) }
        let changed = try XCTUnwrap(model.summaries.first)
        XCTAssertNotEqual(changed.frozenGalleryURL, payload.committedSession.galleryURL)
        XCTAssertEqual(model.galleryStatus(for: changed), .unknown)
    }

    func testBackgroundProofSupersedesEarlierRecheckFailureBeforeQueueClear() async throws {
        let archive = try RecentSessionArchiveStore(directoryURL: root.appendingPathComponent("archive"))
        let evidence = try GalleryVerificationStore(directory: root.appendingPathComponent("evidence"))
        let summary = RecentSessionArchiveSummary(archiveID: token, sessionIdentifier: sessionID, createdAt: Date(), format: .solo, eventName: nil, eventLocation: nil,
            photoCount: 1, receiptWidth: 576, receiptHeight: 1000, estimatedLengthMillimeters: 125, rasterFingerprint: "fixture", thumbnailFilenames: [],
            lastReprintedAt: nil, reprintCount: 0, payloadSizeBytes: 0, frozenGalleryURL: url)
        let queue = try GalleryPendingUploadStore(directoryURL: root.appendingPathComponent("queue"))
        try queue.save(payload()); try queue.updateDeliveryState(.deliveryUnknown, galleryToken: token)
        let pending = try queue.summaries()
        // The fixture's durable queue is independent of the running app's real queue publisher.
        let pendingUpdates = CurrentValueSubject<[GalleryPendingUploadSummary], Never>(pending)
        let model = RecentSessionsViewModel(store: archive, summaryLoader: { [summary] }, verificationStore: evidence, recheckSession: network(), pendingUploadPublisher: pendingUpdates.eraseToAnyPublisher())
        model.refresh()
        while !model.hasLoaded { try await Task.sleep(for: .milliseconds(10)) }
        V41GalleryProtocol.mode = .offline
        model.verifyGalleries([summary])
        while model.isVerifying { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotEqual(model.galleryStatus(for: summary), .verified)
        try evidence.record(sessionID: sessionID, token: token, url: url, source: "background-public-readiness")
        let queuedStatus = ArchivedGalleryStatus.needsAttention(GalleryDeliveryState.deliveryUnknown.operatorTitle)
        for _ in 0..<100 where model.galleryStatus(for: summary) != queuedStatus { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.galleryStatus(for: summary), queuedStatus, "The proof notification was applied while the old queue snapshot was still published")
        pendingUpdates.send([])
        XCTAssertEqual(model.galleryStatus(for: summary), .verified, "An old failed recheck cannot hide a later durable successful delivery")
    }

    func testHistoricalRecheckIsBoundedCancellableAndIncremental() async throws {
        let archive = try RecentSessionArchiveStore(directoryURL: root.appendingPathComponent("archive"))
        let evidence = try GalleryVerificationStore(directory: root.appendingPathComponent("evidence"))
        let summary = RecentSessionArchiveSummary(archiveID: token, sessionIdentifier: sessionID, createdAt: Date(), format: .solo, eventName: nil, eventLocation: nil,
            photoCount: 1, receiptWidth: 576, receiptHeight: 1000, estimatedLengthMillimeters: 125, rasterFingerprint: "fixture", thumbnailFilenames: [], lastReprintedAt: nil,
            reprintCount: 0, payloadSizeBytes: 0, frozenGalleryURL: url)
        let second = RecentSessionArchiveSummary(archiveID: String(repeating: "b", count: 64), sessionIdentifier: "PP-other", createdAt: Date(), format: .solo, eventName: nil, eventLocation: nil,
            photoCount: 1, receiptWidth: 576, receiptHeight: 1000, estimatedLengthMillimeters: 125, rasterFingerprint: "fixture", thumbnailFilenames: [], lastReprintedAt: nil,
            reprintCount: 0, payloadSizeBytes: 0, frozenGalleryURL: URL(string: "https://gallery-fixture.example.test/?g=\(String(repeating: "b", count: 64))")!)
        let model = RecentSessionsViewModel(store: archive, summaryLoader: { [summary, second] }, verificationStore: evidence, recheckSession: network())
        model.refresh()
        while !model.hasLoaded { try await Task.sleep(for: .milliseconds(10)) }
        model.verifyGalleries([summary, second])
        for _ in 0..<100 where model.galleryStatus(for: summary) != .verified { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.galleryStatus(for: summary), .verified)
        model.cancelVerification()
        while model.isVerifying { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(V41GalleryProtocol.methods, ["GET"], "Cancellation during the rate-limit interval skips later requests")
        XCTAssertTrue(model.verificationResult.contains("1 verified")); XCTAssertTrue(model.verificationResult.contains("1 skipped"))
        let relaunched = RecentSessionsViewModel(store: archive, summaryLoader: { [summary] }, verificationStore: evidence)
        relaunched.refresh()
        for _ in 0..<100 where relaunched.galleryStatus(for: summary) != .verified { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(relaunched.galleryStatus(for: summary), .verified)
    }
}

private enum V41GalleryMode: Sendable { case complete, wrongToken, wrongSession, wrongCount, wrongSchema, incomplete, empty200, notFound, offline, legacy, unavailable, rateLimited, redirectedGallery }
private final class V41GalleryProtocol: URLProtocol {
    nonisolated(unsafe) static var mode = V41GalleryMode.complete
    nonisolated(unsafe) static var methods: [String] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.methods.append(request.httpMethod ?? "GET")
        if Self.mode == .offline { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return }
        let token = String(repeating: "d", count: 64)
        let body: String
        if request.httpMethod == "POST" {
            body = "{\"ok\":true,\"schemaVersion\":2,\"galleryToken\":\"\(token)\",\"galleryURL\":\"https://gallery-fixture.example.test/?g=\(token)\",\"fileCount\":4,\"status\":\"existingComplete\"}"
        } else if Self.mode == .unavailable { body = "{\"statusVersion\":1,\"ok\":false,\"status\":\"unavailable\"}" }
        else if Self.mode == .legacy { body = "<main data-pocket-pixels-gallery-status=\"complete\"></main>" }
        else if Self.mode == .empty200 { body = "<main>Not ready</main>" }
        else {
            body = "{\"statusVersion\":1,\"ok\":true,\"status\":\"\(Self.mode == .incomplete ? "pending" : "complete")\",\"galleryToken\":\"\(Self.mode == .wrongToken ? "wrong" : token)\",\"sessionID\":\"\(Self.mode == .wrongSession ? "PP-wrong" : "PP-20261025-120000")\",\"schemaVersion\":\(Self.mode == .wrongSchema ? 3 : 2),\"fileCount\":\(Self.mode == .wrongCount ? 3 : 4)}"
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: Self.mode == .redirectedGallery ? URL(string: "https://gallery-fixture.example.test/?g=other")! : request.url!, statusCode: Self.mode == .notFound ? 404 : Self.mode == .rateLimited ? 429 : 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
