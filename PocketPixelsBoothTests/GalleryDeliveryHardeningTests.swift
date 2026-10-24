import Foundation
import UIKit
import XCTest
@testable import PocketPixelsBooth

@MainActor
final class GalleryDeliveryHardeningTests: XCTestCase {
    func testNetworkAndBackendFailuresRetainDurablePhotosAcrossRestart() async throws {
        for scenario in [DeliveryStub.offline, .lostConnection, .timeout, .malformed, .pendingPage, .unauthorized, .busy, .serverError, .rejected] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let queue = try GalleryPendingUploadStore(directoryURL: directory)
            let token = String(repeating: "e", count: 64)
            let image = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 80)).image { context in
                UIColor.gray.setFill(); context.fill(CGRect(x: 0, y: 0, width: 64, height: 80))
            }
            let payload = try GoogleDriveGalleryUploadService.preparePayload(photos: [image], composedReceipt: image, sessionID: "PP-DELIVERY-TEST", createdAt: Date(), galleryToken: token, customerGalleryBaseURL: URL(string: "https://delivery-fixture.example.test")!)
            try queue.save(payload)
            DeliveryProtocol.scenario = scenario
            DeliveryProtocol.requests = []
            DeliveryProtocol.queueDirectory = directory
            DeliveryProtocol.metadataBeforePOST = nil
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [DeliveryProtocol.self]
            var verifiedSessions: [String] = []
            let service = GoogleDriveGalleryUploadService(
                configurationProvider: { try GoogleDriveGalleryConfiguration.validate(rawValue: "https://script.google.com/macros/s/TEST/exec") },
                urlSession: URLSession(configuration: configuration), pendingStore: queue, onPublicGalleryVerified: { verifiedSessions.append($0) })
            do {
                _ = try await service.uploadPendingGallery(galleryToken: token, deviceToken: String(repeating: "x", count: 32))
                XCTFail("\(scenario) must not report delivery")
            } catch { }
            let attemptedMetadata = try XCTUnwrap(DeliveryProtocol.metadataBeforePOST)
            let metadataObject = try XCTUnwrap(JSONSerialization.jsonObject(with: attemptedMetadata) as? [String: Any])
            let stateBeforePOST = try XCTUnwrap(metadataObject["deliveryState"] as? [String: Any])
            XCTAssertNotNil(stateBeforePOST["deliveryUnknown"], "Every transmitted attempt is durably marked unknown before sending")
            let reopened = try GalleryPendingUploadStore(directoryURL: directory)
            let retained = try XCTUnwrap(reopened.load(galleryToken: token))
            XCTAssertEqual(retained.photos.map(\.data), payload.photos.map(\.data))
            XCTAssertEqual(retained.thermalReceipt?.data, payload.thermalReceipt?.data)
            XCTAssertEqual(try reopened.summaries().first?.retryAttemptCount, 1)
            if [.lostConnection, .timeout, .malformed, .serverError].contains(scenario) {
                XCTAssertEqual(retained.deliveryState, .deliveryUnknown, "\(scenario)")
            }
            if scenario == .pendingPage {
                XCTAssertEqual(retained.deliveryState, .posted, "An accepted POST retries verification only")
                XCTAssertEqual(DeliveryProtocol.requests.map(\.httpMethod), ["POST", "GET"])
                XCTAssertEqual(URLComponents(url: try XCTUnwrap(DeliveryProtocol.requests.last?.url), resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "galleryStatus" })?.value, "1")
                XCTAssertNil(DeliveryProtocol.requests.last?.value(forHTTPHeaderField: "Authorization"))
                XCTAssertEqual(DeliveryProtocol.requests.last?.timeoutInterval, 30)
            }
            XCTAssertTrue(verifiedSessions.isEmpty, "Unknown delivery must never become a verified report")
            // Network restoration retries exactly the persisted identity and clears only after
            // both backend acceptance and the frozen public page's completion marker.
            DeliveryProtocol.scenario = .complete
            let result = try await service.uploadPendingGallery(galleryToken: token, deviceToken: String(repeating: "x", count: 32))
            XCTAssertEqual(result.galleryURL, payload.galleryURL)
            XCTAssertNil(try reopened.load(galleryToken: token))
            XCTAssertEqual(verifiedSessions, [payload.sessionID])
        }
    }

    func testRetryAllContinuesAfterFailureAndReconcilesWithoutAnotherPOST() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = try GalleryPendingUploadStore(directoryURL: directory)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 80)).image { _ in }
        let tokens = ["a", "b", "c"].map { String(repeating: $0, count: 64) }
        for (index, token) in tokens.enumerated() {
            let payload = try GoogleDriveGalleryUploadService.preparePayload(photos: [image], composedReceipt: image,
                sessionID: "PP-HOTFIX-\(index)", createdAt: Date().addingTimeInterval(Double(index)),
                galleryToken: token, customerGalleryBaseURL: URL(string: "https://delivery-fixture.example.test")!)
            try queue.save(payload)
        }
        HotfixProtocol.failedToken = tokens[0]
        HotfixProtocol.publicReady = []
        HotfixProtocol.postTokens = []
        HotfixProtocol.activePosts = 0
        HotfixProtocol.maxActivePosts = 0
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HotfixProtocol.self]
        let service = GoogleDriveGalleryUploadService(
            configurationProvider: { try GoogleDriveGalleryConfiguration.validate(rawValue: "https://script.google.com/macros/s/TEST/exec") },
            urlSession: URLSession(configuration: configuration), pendingStore: queue)
        do {
            _ = try await service.retryPendingQueue(deviceToken: String(repeating: "x", count: 32), maxAttemptsPerGallery: 1)
            XCTFail("Partial failure must be reported truthfully")
        } catch let failure as GalleryPendingQueueFailure {
            XCTAssertEqual(failure.failedCount, 1)
            XCTAssertEqual(failure.successfulResults.map(\.galleryToken), Array(tokens.dropFirst()))
        }
        XCTAssertEqual(HotfixProtocol.postTokens, tokens, "Retry All must reach every gallery")
        XCTAssertEqual(try queue.summaries().map(\.galleryToken), [tokens[0]])
        let retained = try XCTUnwrap(queue.load(galleryToken: tokens[0]))
        let restartedQueue = try GalleryPendingUploadStore(directoryURL: directory)
        XCTAssertEqual(try restartedQueue.load(galleryToken: tokens[0])?.photos.map(\.data), retained.photos.map(\.data))
        // Wi-Fi/public verification recovers after a backend-accepted but ambiguous attempt.
        HotfixProtocol.publicReady.insert(tokens[0])
        let result = try await service.uploadPendingGallery(galleryToken: tokens[0], deviceToken: String(repeating: "x", count: 32))
        XCTAssertEqual(result.galleryToken, retained.galleryToken)
        XCTAssertEqual(result.galleryURL, retained.galleryURL)
        XCTAssertEqual(HotfixProtocol.postTokens, tokens, "Public reconciliation must avoid re-uploading files")
        XCTAssertTrue(try restartedQueue.summaries().isEmpty)
    }

    func testColdPublicPageTakingLongerThanEightSecondsReconcilesWithoutPOST() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = try GalleryPendingUploadStore(directoryURL: directory)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 80)).image { _ in }
        let token = String(repeating: "b", count: 64)
        let payload = try GoogleDriveGalleryUploadService.preparePayload(photos: [image], composedReceipt: image,
            sessionID: "PP-COLD-PUBLIC", createdAt: Date(), galleryToken: token,
            customerGalleryBaseURL: URL(string: "https://delivery-fixture.example.test")!)
        try queue.save(payload)
        try queue.updateDeliveryState(.deliveryUnknown, galleryToken: token)
        HotfixProtocol.publicReady = [token]
        HotfixProtocol.postTokens = []
        HotfixProtocol.publicDelay = 9
        defer { HotfixProtocol.publicDelay = 0 }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HotfixProtocol.self]
        let service = GoogleDriveGalleryUploadService(
            configurationProvider: { try GoogleDriveGalleryConfiguration.validate(rawValue: "https://script.google.com/macros/s/TEST/exec") },
            urlSession: URLSession(configuration: configuration), pendingStore: queue)
        let result = try await service.uploadPendingGallery(galleryToken: token, deviceToken: String(repeating: "x", count: 32))
        XCTAssertEqual(result.galleryURL, payload.galleryURL)
        XCTAssertTrue(HotfixProtocol.postTokens.isEmpty, "A slow completed page must not trigger another upload")
        XCTAssertNil(try queue.load(galleryToken: token))
    }

    func testPublicSweepRecoversLaterReadyGalleriesBeforeSlowUpload() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = try GalleryPendingUploadStore(directoryURL: directory)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 80)).image { _ in }
        let tokens = ["a", "b", "c"].map { String(repeating: $0, count: 64) }
        for (index, token) in tokens.enumerated() {
            try queue.save(GoogleDriveGalleryUploadService.preparePayload(photos: [image], composedReceipt: image,
                sessionID: "PP-SWEEP-\(index)", createdAt: Date().addingTimeInterval(Double(index)), galleryToken: token,
                customerGalleryBaseURL: URL(string: "https://delivery-fixture.example.test")!))
            try queue.updateDeliveryState(.deliveryUnknown, galleryToken: token)
        }
        HotfixProtocol.failedToken = tokens[0]
        HotfixProtocol.publicReady = Set(tokens.dropFirst())
        HotfixProtocol.postTokens = []
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HotfixProtocol.self]
        let service = GoogleDriveGalleryUploadService(
            configurationProvider: { try GoogleDriveGalleryConfiguration.validate(rawValue: "https://script.google.com/macros/s/TEST/exec") },
            urlSession: URLSession(configuration: configuration), pendingStore: queue)
        do {
            _ = try await service.retryPendingQueue(deviceToken: String(repeating: "x", count: 32))
            XCTFail("The first pending public page must remain queued")
        } catch let failure as GalleryPendingQueueFailure {
            XCTAssertEqual(failure.successfulResults.map(\.galleryToken), Array(tokens.dropFirst()))
            XCTAssertEqual(failure.failedCount, 1)
        }
        XCTAssertEqual(HotfixProtocol.postTokens, [tokens[0]], "Already-public galleries must never POST")
        XCTAssertEqual(try queue.summaries().map(\.galleryToken), [tokens[0]])
    }

    func testSimultaneousTriggersAndCancelCannotReleaseAnotherUploadLock() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = try GalleryPendingUploadStore(directoryURL: directory)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 80)).image { _ in }
        let tokens = ["d", "f"].map { String(repeating: $0, count: 64) }
        for (index, token) in tokens.enumerated() {
            try queue.save(GoogleDriveGalleryUploadService.preparePayload(photos: [image], composedReceipt: image,
                sessionID: "PP-CONCURRENT-\(index)", createdAt: Date(), galleryToken: token,
                customerGalleryBaseURL: URL(string: "https://delivery-fixture.example.test")!))
        }
        HotfixProtocol.failedToken = nil
        HotfixProtocol.publicReady = []
        HotfixProtocol.postTokens = []
        HotfixProtocol.activePosts = 0
        HotfixProtocol.maxActivePosts = 0
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HotfixProtocol.self]
        func makeService() -> GoogleDriveGalleryUploadService {
            GoogleDriveGalleryUploadService(
                configurationProvider: { try GoogleDriveGalleryConfiguration.validate(rawValue: "https://script.google.com/macros/s/TEST/exec") },
                urlSession: URLSession(configuration: configuration), pendingStore: queue)
        }
        let first = makeService(), second = makeService()
        let task = Task { try await first.retryPendingQueue(deviceToken: String(repeating: "x", count: 32), maxAttemptsPerGallery: 1) }
        while HotfixProtocol.postTokens.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        second.cancel()
        do {
            _ = try await second.retryPendingQueue(deviceToken: String(repeating: "x", count: 32))
            XCTFail("A second queue worker must not compete")
        } catch GalleryUploadError.uploadAlreadyActive { }
        _ = try await second.uploadPendingGallery(galleryToken: tokens[1], deviceToken: String(repeating: "x", count: 32))
        _ = try await task.value
        XCTAssertEqual(HotfixProtocol.maxActivePosts, 1)
        XCTAssertEqual(Set(HotfixProtocol.postTokens), Set(tokens))
        XCTAssertEqual(HotfixProtocol.postTokens.count, 2)
        XCTAssertTrue(try queue.summaries().isEmpty)
    }

    func testCancelAndStartAnotherSessionNeverDeleteQueuedGallery() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = try GalleryPendingUploadStore(directoryURL: directory)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 80)).image { _ in }
        let payload = try GoogleDriveGalleryUploadService.preparePayload(photos: [image], composedReceipt: image, sessionID: "PP-PREVIOUS-GUEST", createdAt: Date(), galleryToken: String(repeating: "f", count: 64), customerGalleryBaseURL: URL(string: "https://delivery-fixture.example.test")!)
        try queue.save(payload)
        let model = BoothSessionViewModel()
        model.configurePaidCheckoutForTesting(qrPhEnabled: false, cashEnabled: true)
        model.cancelSession()
        model.state = .thankYou
        model.resetAfterDone()
        XCTAssertEqual(try queue.load(galleryToken: payload.galleryToken)?.photos.map(\.data), payload.photos.map(\.data))
        XCTAssertNil(model.galleryURL)
        XCTAssertTrue(model.capturedPhotos.isEmpty)
    }
}

private enum DeliveryStub: String, Sendable {
    case offline, lostConnection, timeout, malformed, pendingPage, unauthorized, busy, serverError, rejected, complete
}
private final class DeliveryProtocol: URLProtocol {
    nonisolated(unsafe) static var scenario: DeliveryStub = .complete
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var queueDirectory: URL?
    nonisolated(unsafe) static var metadataBeforePOST: Data?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        if request.httpMethod == "POST", let directory = Self.queueDirectory {
            Self.metadataBeforePOST = try? Data(contentsOf: directory.appendingPathComponent(String(repeating: "e", count: 64)).appendingPathComponent("metadata.json"))
        }
        let errorCode: URLError.Code? = switch Self.scenario {
        case .offline: .notConnectedToInternet
        case .lostConnection: .networkConnectionLost
        case .timeout: .timedOut
        default: nil
        }
        if let errorCode { client?.urlProtocol(self, didFailWithError: URLError(errorCode)); return }
        let status = Self.scenario == .unauthorized ? 401 : Self.scenario == .busy ? 429 : Self.scenario == .serverError ? 500 : 200
        let body: String
        if request.httpMethod == "GET" {
            body = Self.scenario == .pendingPage ? "<main data-gallery-state=\"pending\"></main>" : "<main data-pocket-pixels-gallery-status=\"complete\"></main>"
        } else if Self.scenario == .malformed {
            body = "<html>temporarily unavailable</html>"
        } else if Self.scenario == .rejected {
            body = "{\"ok\":false,\"error\":\"Upload rejected\"}"
        } else {
            let token = String(repeating: "e", count: 64)
            body = "{\"ok\":true,\"schemaVersion\":2,\"galleryToken\":\"\(token)\",\"galleryURL\":\"https://delivery-fixture.example.test/?g=\(token)\",\"fileCount\":4,\"status\":\"created\"}"
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class HotfixProtocol: URLProtocol {
    nonisolated(unsafe) static var publicDelay: TimeInterval = 0
    nonisolated(unsafe) static var failedToken: String?
    nonisolated(unsafe) static var publicReady: Set<String> = []
    nonisolated(unsafe) static var postTokens: [String] = []
    nonisolated(unsafe) static var activePosts = 0
    nonisolated(unsafe) static var maxActivePosts = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if request.httpMethod == "POST" {
            var data = request.httpBody ?? Data()
            if data.isEmpty, let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    data.append(contentsOf: buffer.prefix(count))
                }
            }
            let token = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["galleryToken"] as? String ?? ""
            Self.postTokens.append(token)
            Self.activePosts += 1
            Self.maxActivePosts = max(Self.maxActivePosts, Self.activePosts)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [self] in
                Self.activePosts -= 1
                if token != Self.failedToken { Self.publicReady.insert(token) }
                finish(body: "{\"ok\":true,\"schemaVersion\":2,\"galleryToken\":\"\(token)\",\"galleryURL\":\"https://delivery-fixture.example.test/?g=\(token)\",\"fileCount\":4,\"status\":\"existingComplete\"}")
            }
        } else {
            let token = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "g" })?.value ?? ""
            let body = Self.publicReady.contains(token) ? "<main data-pocket-pixels-gallery-status=\"complete\"></main>" : "<main>pending</main>"
            if Self.publicDelay > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.publicDelay) { [self] in finish(body: body) }
            } else {
                finish(body: body)
            }
        }
    }
    private func finish(body: String) {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
