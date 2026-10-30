import XCTest
import UIKit
@testable import PocketPixelsBooth

@MainActor
final class GalleryUploadPerformanceTests: XCTestCase {
    func testAcceptedGalleryRelaunchVerifiesWithoutOpeningMediaAndNextGuestCanUpload() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try GalleryPendingUploadStore(directoryURL: root)
        let image = ReliabilityFixtures.syntheticPhoto(session: 555, photo: 0, format: .solo)
        let token = String(repeating: "b", count: 64)
        let payload = try GoogleDriveGalleryUploadService.preparePayload(photos: [image], composedReceipt: image,
            sessionID: "PP-20261020-120000", createdAt: Date(), galleryToken: token,
            customerGalleryBaseURL: URL(string: "https://speed.example.test/")!,
            receiptVariants: GalleryReceiptVariants(originalFooterStyle: .decorativeBarcodeOnly, defaultStyle: .shareFriendly))
        try store.save(payload)
        try store.updateDeliveryState(.posted, galleryToken: token) // Acknowledgement persisted before process loss.
        // A posted gallery must not read even a single photograph file during recovery.
        try FileManager.default.removeItem(at: root.appendingPathComponent(token).appendingPathComponent("photo-01.jpg"))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReadinessProtocol.self]
        func reopened() throws -> GoogleDriveGalleryUploadService {
            GoogleDriveGalleryUploadService(
                configurationProvider: { try GoogleDriveGalleryConfiguration.validate(rawValue: "https://script.google.com/macros/s/TEST/exec") },
                urlSession: URLSession(configuration: configuration), pendingStore: try GalleryPendingUploadStore(directoryURL: root),
                verificationStore: try GalleryVerificationStore(directory: root.appendingPathComponent("proof")),
                scheduler: GalleryUploadScheduler(), onPublicGalleryVerified: { _ in })
        }
        ReadinessProtocol.responseToken = token
        ReadinessProtocol.responseSession = payload.sessionID
        defer { ReadinessProtocol.responseToken = String(repeating: "b", count: 64); ReadinessProtocol.responseSession = "PP-20261020-120000" }
        ReadinessProtocol.scenario = "wrongSession"; ReadinessProtocol.requests = []
        do { _ = try await reopened().uploadPendingGallery(galleryToken: token, deviceToken: "synthetic-only-placeholder-token"); XCTFail("Stale identity cannot clear accepted work") } catch { }
        XCTAssertEqual(try store.delivery(galleryToken: token)?.state, .posted)
        XCTAssertEqual(ReadinessProtocol.requests.map(\.httpMethod), ["GET"])
        ReadinessProtocol.scenario = "valid"; ReadinessProtocol.requests = []
        var stages: [GalleryUploadPhase] = []
        let relaunched = try reopened()
        relaunched.onStageChange = { _, phase in stages.append(phase) }
        _ = try await relaunched.uploadPendingGallery(galleryToken: token, deviceToken: "synthetic-only-placeholder-token")
        XCTAssertEqual(ReadinessProtocol.requests.map(\.httpMethod), ["GET"])
        XCTAssertNil(try store.delivery(galleryToken: token))
        XCTAssertEqual(stages, [.verifying, .success(payload.galleryURL)])
        // Following guest/event can reuse the queue without historical evidence acting as a gate.
        let next = try GoogleDriveGalleryUploadService.preparePayload(photos: [image], composedReceipt: image,
            sessionID: "PP-20261020-120001", createdAt: Date(), galleryToken: String(repeating: "c", count: 64),
            customerGalleryBaseURL: URL(string: "https://speed.example.test/")!,
            receiptVariants: GalleryReceiptVariants(originalFooterStyle: .decorativeBarcodeOnly, defaultStyle: .shareFriendly))
        try store.save(next)
        ReadinessProtocol.responseToken = next.galleryToken; ReadinessProtocol.responseSession = next.sessionID
        ReadinessProtocol.requests = []; stages = []
        _ = try await relaunched.uploadPendingGallery(galleryToken: next.galleryToken, deviceToken: "synthetic-only-placeholder-token")
        XCTAssertEqual(ReadinessProtocol.requests.map(\.httpMethod), ["POST", "GET"])
        XCTAssertEqual(stages, [.uploading, .processing, .verifying, .success(next.galleryURL)])
    }

    func testVerifiedUnknownUploadWithDiskCommitFailureNeverFallsThroughToPOST() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try GalleryPendingUploadStore(fileManager: FailingGalleryClearFileManager(), directoryURL: root)
        let image = ReliabilityFixtures.syntheticPhoto(session: 555, photo: 0, format: .solo)
        let token = String(repeating: "b", count: 64)
        let payload = try GoogleDriveGalleryUploadService.preparePayload(photos: [image], composedReceipt: image,
            sessionID: "PP-20261020-120000", createdAt: Date(), galleryToken: token,
            customerGalleryBaseURL: URL(string: "https://speed.example.test/")!,
            receiptVariants: GalleryReceiptVariants(originalFooterStyle: .decorativeBarcodeOnly, defaultStyle: .shareFriendly))
        try store.save(payload); try store.updateDeliveryState(.deliveryUnknown, galleryToken: token)
        ReadinessProtocol.scenario = "valid"; ReadinessProtocol.requests = []
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ReadinessProtocol.self]
        let service = GoogleDriveGalleryUploadService(urlSession: URLSession(configuration: config), pendingStore: store,
            verificationStore: try GalleryVerificationStore(directory: root.appendingPathComponent("proof")),
            scheduler: GalleryUploadScheduler(), onPublicGalleryVerified: { _ in })
        do { _ = try await service.uploadPendingGallery(galleryToken: token, deviceToken: "synthetic-only-placeholder-token"); XCTFail("Failed local clear must be surfaced") } catch { }
        XCTAssertEqual(ReadinessProtocol.requests.map(\.httpMethod), ["GET"])
        XCTAssertEqual(try store.delivery(galleryToken: token)?.state, .posted)
        XCTAssertEqual(try store.load(galleryToken: token)?.photos.map(\.data), payload.photos.map(\.data))
        let diskRanOnMain = try await GalleryDiskIO.shared.run { Thread.isMainThread }
        XCTAssertFalse(diskRanOnMain)
    }

    func testLightweightReadinessRequiresExactPersistedIdentityBeforeClearingQueue() async throws {
        for scenario in ["valid", "legacyHTML", "wrongToken", "wrongSession", "wrongCount", "pending", "badVersion", "malformed"] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = try GalleryPendingUploadStore(directoryURL: directory)
            let image = ReliabilityFixtures.syntheticPhoto(session: 555, photo: 0, format: .solo)
            let payload = try GoogleDriveGalleryUploadService.preparePayload(photos: [image], composedReceipt: image,
                sessionID: "PP-20261020-120000", createdAt: Date(), galleryToken: String(repeating: "b", count: 64),
                customerGalleryBaseURL: URL(string: "https://speed.example.test/")!,
                receiptVariants: GalleryReceiptVariants(originalFooterStyle: .decorativeBarcodeOnly, defaultStyle: .shareFriendly))
            XCTAssertEqual(payload.schemaVersion, 4)
            XCTAssertNil(payload.thermalReceipt)
            try store.save(payload)
            ReadinessProtocol.scenario = scenario; ReadinessProtocol.requests = []
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ReadinessProtocol.self]
            var verified = 0
            let service = GoogleDriveGalleryUploadService(
                configurationProvider: { try GoogleDriveGalleryConfiguration.validate(rawValue: "https://script.google.com/macros/s/TEST/exec") },
                urlSession: URLSession(configuration: configuration), pendingStore: store, onPublicGalleryVerified: { _ in verified += 1 })
            let shouldPass = ["valid", "legacyHTML"].contains(scenario)
            do {
                _ = try await service.uploadPendingGallery(galleryToken: payload.galleryToken, deviceToken: String(repeating: "x", count: 32))
                XCTAssertTrue(shouldPass, scenario)
            } catch { XCTAssertFalse(shouldPass, "\(scenario): \(error)") }
            XCTAssertEqual(verified, shouldPass ? 1 : 0)
            XCTAssertEqual(try store.load(galleryToken: payload.galleryToken) == nil, shouldPass)
            let request = try XCTUnwrap(ReadinessProtocol.requests.last)
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "galleryStatus" })?.value, "1")
        }
    }
}

private final class ReadinessProtocol: URLProtocol {
    nonisolated(unsafe) static var responseToken = String(repeating: "b", count: 64)
    nonisolated(unsafe) static var responseSession = "PP-20261020-120000"
    nonisolated(unsafe) static var scenario = "valid"
    nonisolated(unsafe) static var requests: [URLRequest] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        let token = Self.responseToken
        var value: [String: Any] = ["ok": true, "schemaVersion": 4, "galleryToken": token, "galleryURL": "https://speed.example.test/?g=\(token)", "fileCount": 3, "status": "created"]
        var data: Data
        if request.httpMethod == "GET" {
            value = ["statusVersion": 1, "ok": true, "status": "complete", "galleryToken": token, "sessionID": Self.responseSession, "schemaVersion": 4, "fileCount": 3]
            switch Self.scenario {
            case "wrongToken": value["galleryToken"] = String(repeating: "c", count: 64)
            case "wrongSession": value["sessionID"] = "PP-20261020-120001"
            case "wrongCount": value["fileCount"] = 4
            case "pending": value["status"] = "pending"; value["ok"] = false
            case "badVersion": value["statusVersion"] = 2
            default: break
            }
        }
        data = try! JSONSerialization.data(withJSONObject: value)
        if request.httpMethod == "GET", Self.scenario == "legacyHTML" { data = Data("<main data-pocket-pixels-gallery-status=\"complete\"></main>".utf8) }
        if request.httpMethod == "GET", Self.scenario == "malformed" { data = Data("{}".utf8) }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class FailingGalleryClearFileManager: FileManager, @unchecked Sendable {
    override func removeItem(at URL: URL) throws {
        if GalleryTokenGenerator.isValidGalleryToken(URL.lastPathComponent) { throw CocoaError(.fileWriteNoPermission) }
        try super.removeItem(at: URL)
    }
}
