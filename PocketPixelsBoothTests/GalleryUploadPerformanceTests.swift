import XCTest
import UIKit
@testable import PocketPixelsBooth

@MainActor
final class GalleryUploadPerformanceTests: XCTestCase {
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
    nonisolated(unsafe) static var scenario = "valid"
    nonisolated(unsafe) static var requests: [URLRequest] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        let token = String(repeating: "b", count: 64)
        var value: [String: Any] = ["ok": true, "schemaVersion": 4, "galleryToken": token, "galleryURL": "https://speed.example.test/?g=\(token)", "fileCount": 3, "status": "created"]
        var data: Data
        if request.httpMethod == "GET" {
            value = ["statusVersion": 1, "ok": true, "status": "complete", "galleryToken": token, "sessionID": "PP-20261020-120000", "schemaVersion": 4, "fileCount": 3]
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
