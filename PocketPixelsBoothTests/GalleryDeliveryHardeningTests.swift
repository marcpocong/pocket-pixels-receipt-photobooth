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
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [DeliveryProtocol.self]
            let service = GoogleDriveGalleryUploadService(
                configurationProvider: { try GoogleDriveGalleryConfiguration.validate(rawValue: "https://script.google.com/macros/s/TEST/exec") },
                urlSession: URLSession(configuration: configuration), pendingStore: queue)
            do {
                _ = try await service.uploadPendingGallery(galleryToken: token, deviceToken: String(repeating: "x", count: 32))
                XCTFail("\(scenario) must not report delivery")
            } catch { }
            let reopened = try GalleryPendingUploadStore(directoryURL: directory)
            let retained = try XCTUnwrap(reopened.load(galleryToken: token))
            XCTAssertEqual(retained.photos.map(\.data), payload.photos.map(\.data))
            XCTAssertEqual(retained.thermalReceipt?.data, payload.thermalReceipt?.data)
            XCTAssertEqual(try reopened.summaries().first?.retryAttemptCount, 1)
            if [.lostConnection, .timeout, .malformed, .pendingPage, .serverError].contains(scenario) {
                XCTAssertEqual(retained.deliveryState, .deliveryUnknown, "\(scenario)")
            }
            if scenario == .pendingPage {
                XCTAssertEqual(DeliveryProtocol.requests.map(\.httpMethod), ["POST", "GET"])
                XCTAssertEqual(DeliveryProtocol.requests.last?.url, payload.galleryURL)
                XCTAssertNil(DeliveryProtocol.requests.last?.value(forHTTPHeaderField: "Authorization"))
                XCTAssertEqual(DeliveryProtocol.requests.last?.timeoutInterval, 8)
            }
            // Network restoration retries exactly the persisted identity and clears only after
            // both backend acceptance and the frozen public page's completion marker.
            DeliveryProtocol.scenario = .complete
            let result = try await service.uploadPendingGallery(galleryToken: token, deviceToken: String(repeating: "x", count: 32))
            XCTAssertEqual(result.galleryURL, payload.galleryURL)
            XCTAssertNil(try reopened.load(galleryToken: token))
        }
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
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
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
