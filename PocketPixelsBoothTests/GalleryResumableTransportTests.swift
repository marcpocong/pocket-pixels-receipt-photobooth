import CryptoKit
import Foundation
import UIKit
import XCTest
@testable import PocketPixelsBooth

@MainActor final class GalleryResumableTransportTests: XCTestCase {
    private func setupFixture() throws -> (URL, GalleryPendingUploadStore, GalleryPreparedUploadPayload, ResumableFixture) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try GalleryPendingUploadStore(directoryURL: root)
        let image = GalleryPipelineBenchmarkTests.photo(seed: 7)
        let payload = try GoogleDriveGalleryUploadService.preparePayload(photos: [image], composedReceipt: image,
            sessionID: "PP-20261111-120000", createdAt: Date(), galleryToken: String(repeating: "b", count: 64),
            customerGalleryBaseURL: URL(string: "https://resumable.example.test/")!,
            receiptVariants: GalleryReceiptVariants(originalFooterStyle: .decorativeBarcodeOnly, defaultStyle: .shareFriendly))
        try store.save(payload)
        let fixture = ResumableFixture(payload: payload)
        ResumableProtocol.fixture = fixture
        return (root, store, payload, fixture)
    }

    private func service(_ store: GalleryPendingUploadStore, root: URL, endpoint: URL) throws -> GoogleDriveGalleryUploadService {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [ResumableProtocol.self]
        return GoogleDriveGalleryUploadService(transportPreference: .resumable, configurationProvider: { try GoogleDriveGalleryConfiguration.validate(rawValue: endpoint.absoluteString) },
            urlSession: URLSession(configuration: configuration), pendingStore: store,
            verificationStore: try GalleryVerificationStore(directory: root.appendingPathComponent("proof")),
            scheduler: GalleryUploadScheduler(), onPublicGalleryVerified: { _ in })
    }

    func testLostChunkAcknowledgmentResumesAtServerOffsetAfterRelaunchWithoutResendingAcceptedBytes() async throws {
        let (root, store, payload, fixture) = try setupFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        fixture.loseFirstChunkAcknowledgment = true
        let endpoint = fixture.endpoint
        let first = try service(store, root: root, endpoint: endpoint)
        do { _ = try await first.uploadPendingGallery(galleryToken: payload.galleryToken, deviceToken: "synthetic-device-credential"); XCTFail("Lost ACK must remain uncertain") }
        catch { }
        XCTAssertNotNil(try store.load(galleryToken: payload.galleryToken))
        XCTAssertEqual(fixture.transmittedBytes, 256 * 1024)
        XCTAssertNotNil(try store.transferJournal(galleryToken: payload.galleryToken))
        let reopened = try GalleryPendingUploadStore(directoryURL: root)
        try reopened.requestRetry(connectivityRestored: true)
        let resumed = try service(reopened, root: root, endpoint: endpoint)
        _ = try await resumed.retryPendingQueue(deviceToken: "synthetic-device-credential")
        XCTAssertTrue(try reopened.summaries().isEmpty)
        XCTAssertEqual(fixture.transmittedBytes, payload.metrics.totalDecodedBytes, "No already-accepted chunk is retransmitted")
        XCTAssertEqual(fixture.publications, 1)
        XCTAssertEqual(fixture.firstOffsets.filter { $0 == 0 }.count, 2, "Each independent asset starts only once")
        XCTAssertTrue(fixture.binaryAuthorizationHeaders.isEmpty, "No broad credential is given to an asset upload")
    }

    func testPublishedButNotPublicGalleryRetainsMediaAndRetriesOnlyGETAfterRelaunch() async throws {
        let (root, store, payload, fixture) = try setupFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        fixture.publicAvailable = false
        let first = try service(store, root: root, endpoint: fixture.endpoint)
        do { _ = try await first.uploadPendingGallery(galleryToken: payload.galleryToken, deviceToken: "synthetic-device-credential"); XCTFail("Storage is not public delivery") }
        catch { }
        XCTAssertEqual(try store.delivery(galleryToken: payload.galleryToken)?.state, .posted)
        XCTAssertNotNil(try store.load(galleryToken: payload.galleryToken))
        let bytes = fixture.transmittedBytes, writes = fixture.controlPOSTs
        fixture.publicAvailable = true
        let reopened = try GalleryPendingUploadStore(directoryURL: root)
        let next = try service(reopened, root: root, endpoint: fixture.endpoint)
        _ = try await next.uploadPendingGallery(galleryToken: payload.galleryToken, deviceToken: "synthetic-device-credential")
        XCTAssertEqual(fixture.transmittedBytes, bytes)
        XCTAssertEqual(fixture.controlPOSTs, writes)
        XCTAssertTrue(try reopened.summaries().isEmpty)
    }

    func testUntrustedSessionDestinationIsRejectedBeforeAnyMediaLeaves() async throws {
        let (root, store, payload, fixture) = try setupFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        fixture.untrustedUploadURL = true
        let upload = try service(store, root: root, endpoint: fixture.endpoint)
        do { _ = try await upload.uploadPendingGallery(galleryToken: payload.galleryToken, deviceToken: "synthetic-device-credential"); XCTFail("Foreign session URI must be rejected") }
        catch { }
        XCTAssertEqual(fixture.transmittedBytes, 0)
        XCTAssertNotNil(try store.load(galleryToken: payload.galleryToken))
    }

    func testPersistedProtocolDoesNotFallBackToLegacyPOSTAfterCapabilityRollback() async throws {
        let (root, store, payload, fixture) = try setupFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        fixture.loseFirstChunkAcknowledgment = true
        let first = try service(store, root: root, endpoint: fixture.endpoint)
        _ = try? await first.uploadPendingGallery(galleryToken: payload.galleryToken, deviceToken: "synthetic-device-credential")
        fixture.transportAvailable = false
        let next = try service(store, root: root, endpoint: fixture.endpoint)
        _ = try? await next.uploadPendingGallery(galleryToken: payload.galleryToken, deviceToken: "synthetic-device-credential")
        XCTAssertEqual(fixture.legacyPOSTs, 0)
        XCTAssertNotNil(try store.load(galleryToken: payload.galleryToken))
    }

    func testServerRangeValidationNeverTrustsLocalSentByteCount() throws {
        XCTAssertEqual(try GalleryResumableTransport.confirmedOffset(nil, total: 1000), 0)
        XCTAssertEqual(try GalleryResumableTransport.confirmedOffset("bytes=0-511", total: 1000), 512)
        for range in ["bytes=1-511", "bytes=0-1000", "bytes=0--1", "bytes=0-x"] {
            XCTAssertThrowsError(try GalleryResumableTransport.confirmedOffset(range, total: 1000))
        }
    }

    func testConcurrentAssetProgressMergesWithoutOverwritingAnotherDurableOffset() async throws {
        let (root, store, payload, fixture) = try setupFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let command = GalleryResumableTransport.Command(payload, deviceToken: "synthetic-device-credential")
        var journal = GalleryTransferJournal(endpoint: fixture.endpoint)
        for descriptor in command.descriptors {
            journal.assets[descriptor.filename] = .init(filename: descriptor.filename, sha256: descriptor.sha256, bytes: descriptor.bytes)
        }
        try store.saveTransferJournal(journal, galleryToken: payload.galleryToken)
        let assets = Array(journal.assets.values)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for var asset in assets {
                asset.confirmedBytes = min(1024, asset.bytes)
                let progress = asset
                group.addTask { try store.recordTransferAsset(progress, galleryToken: payload.galleryToken) }
            }
            try await group.waitForAll()
        }
        let reopened = try GalleryPendingUploadStore(directoryURL: root)
        let saved = try XCTUnwrap(reopened.transferJournal(galleryToken: payload.galleryToken))
        XCTAssertEqual(saved.assets.count, 2)
        XCTAssertTrue(saved.assets.values.allSatisfy { $0.confirmedBytes == min(1024, $0.bytes) })
        XCTAssertEqual(try reopened.load(galleryToken: payload.galleryToken)?.photos, payload.photos)
        XCTAssertEqual(try reopened.load(galleryToken: payload.galleryToken)?.colorReceipt, payload.colorReceipt)
    }

    func testTransferPolicyAdaptsToMeasuredRateAndConstrainedPaths() {
        let telemetry = GalleryTransferTelemetry()
        XCTAssertFalse(telemetry.prefersSingleRequest, "An unknown path starts with resumable protection")
        var fast = GalleryTransferTelemetry.Sample()
        fast.sent = 2 * 1024 * 1024; fast.expected = fast.sent
        fast.began -= 1; fast.hasBodyProgress = true
        telemetry.update(UUID(), sample: fast, finished: true)
        XCTAssertTrue(telemetry.prefersSingleRequest)
        XCTAssertEqual(telemetry.recommendedAssetConcurrency, 2)
        telemetry.constrainedPath = true
        XCTAssertFalse(telemetry.prefersSingleRequest)
        XCTAssertEqual(telemetry.recommendedAssetConcurrency, 1)
        telemetry.constrainedPath = false
        var slow = GalleryTransferTelemetry.Sample()
        slow.sent = 128 * 1024; slow.expected = slow.sent; slow.began -= 4; slow.hasBodyProgress = true
        telemetry.update(UUID(), sample: slow, finished: true)
        XCTAssertFalse(telemetry.prefersSingleRequest, "A weaker observed path immediately restores resumable protection")
        XCTAssertEqual(telemetry.recommendedAssetConcurrency, 1)
    }

    func testConnectionRecoveryClearsTemporaryCoordinationFailureButPreservesServerCooldown() async throws {
        for code in ["DRIVE_UNAVAILABLE", "UPLOAD_SERVICE_BUSY"] {
            let (root, store, payload, fixture) = try setupFixture()
            defer { try? FileManager.default.removeItem(at: root) }
            fixture.coordinationError = code
            let upload = try service(store, root: root, endpoint: fixture.endpoint)
            _ = try? await upload.uploadPendingGallery(galleryToken: payload.galleryToken, deviceToken: "synthetic-device-credential")
            let failed = try XCTUnwrap(store.summaries().first)
            XCTAssertEqual(failed.retryCategory, code == "UPLOAD_SERVICE_BUSY" ? .rateLimited : .backendUnavailable)
            XCTAssertNotNil(failed.nextAttemptAt)
            try store.requestRetry(connectivityRestored: true)
            let afterPathChange = try XCTUnwrap(store.summaries().first)
            if code == "UPLOAD_SERVICE_BUSY" { XCTAssertEqual(afterPathChange.nextAttemptAt, failed.nextAttemptAt) }
            else { XCTAssertLessThanOrEqual(try XCTUnwrap(afterPathChange.nextAttemptAt), Date()) }
            XCTAssertEqual(fixture.transmittedBytes, 0)
            XCTAssertNotNil(try store.load(galleryToken: payload.galleryToken))
        }
    }
}

private nonisolated final class ResumableFixture: @unchecked Sendable {
    let endpoint = URL(string: "https://script.google.com/macros/s/TEST-\(UUID().uuidString)/exec")!
    let payload: GalleryPreparedUploadPayload
    let lock = NSLock()
    var loseFirstChunkAcknowledgment = false
    var publicAvailable = true
    var untrustedUploadURL = false
    var transportAvailable = true
    var coordinationError: String?
    var transmittedBytes = 0, publications = 0, controlPOSTs = 0, legacyPOSTs = 0
    var firstOffsets: [Int] = [], binaryAuthorizationHeaders: [String] = []
    private var stored: [String: Data] = [:]
    init(payload: GalleryPreparedUploadPayload) { self.payload = payload }
    struct Response { var code = 200; var headers: [String:String] = [:]; var json: [String: Any] = [:]; var error: URLError? }

    func handle(_ request: URLRequest, body: Data) -> Response {
        lock.lock(); defer { lock.unlock() }
        let parts = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        if request.httpMethod == "GET", parts.queryItems?.contains(where: { $0.name == "diagnostic" }) == true {
            return Response(json: ["uploadTransports": transportAvailable ? ["drive-resumable-v1"] : []])
        }
        if request.httpMethod == "GET" {
            if publications > 0 && publicAvailable {
                return Response(json: ["statusVersion":1,"ok":true,"status":"complete","galleryToken":payload.galleryToken,
                    "sessionID":payload.sessionID,"schemaVersion":4,"fileCount":payload.photos.count + 2])
            }
            return Response(json: ["statusVersion":1,"ok":false,"status":"unavailable"])
        }
        if request.httpMethod == "POST" {
            controlPOSTs += 1
            let command = (try? JSONSerialization.jsonObject(with: body)) as? [String:Any] ?? [:]
            guard command["transport"] as? String == "drive-resumable-v1" else { legacyPOSTs += 1; return Response(code:500) }
            guard transportAvailable else { return Response(json:["ok":false,"status":"retryable","errorCode":"TRANSPORT_UNAVAILABLE"]) }
            if let coordinationError { return Response(json:["ok":false,"status":"retryable","errorCode":coordinationError]) }
            if command["action"] as? String == "finalize" {
                publications = 1
                return Response(json:["ok":true,"transport":"drive-resumable-v1","schemaVersion":4,"galleryToken":payload.galleryToken,
                    "galleryURL":payload.galleryURL.absoluteString,"fileCount":payload.photos.count + 2,"status":"created"])
            }
            let images = payload.photos + [payload.colorReceipt]
            return Response(json:["ok":true,"transport":"drive-resumable-v1","galleryToken":payload.galleryToken,"status":"transferring",
                "assets":images.map { image -> [String:Any] in
                    let complete = stored[image.filename]?.count == image.data.count
                    return ["filename":image.filename,"bytes":image.data.count,"sha256":SHA256.hash(data:image.data).map { String(format:"%02x",$0) }.joined(),
                        "stored":complete,"uploadURL":"https://\(untrustedUploadURL ? "foreign.example.test" : "www.googleapis.com")/upload/drive/v3/files?uploadType=resumable&upload_id=\(image.filename)"]
                }])
        }
        if let auth = request.value(forHTTPHeaderField: "Authorization") { binaryAuthorizationHeaders.append(auth) }
        let name = parts.queryItems!.first { $0.name == "upload_id" }!.value!
        let image = (payload.photos + [payload.colorReceipt]).first { $0.filename == name }!
        let range = request.value(forHTTPHeaderField:"Content-Range") ?? ""
        if !range.hasPrefix("bytes */") {
            let start = Int(range.dropFirst(6).split(separator:"-").first!)!
            firstOffsets.append(start)
            if start != (stored[name]?.count ?? 0) { return Response(code:409) }
            stored[name,default:Data()].append(body); transmittedBytes += body.count
            if loseFirstChunkAcknowledgment { loseFirstChunkAcknowledgment = false; return Response(error:URLError(.networkConnectionLost)) }
        }
        let count = stored[name]?.count ?? 0
        if count == image.data.count { return Response(json:["size":count]) }
        return Response(code:308,headers:count > 0 ? ["Range":"bytes=0-\(count-1)"] : [:])
    }
}

private nonisolated final class ResumableProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var fixture: ResumableFixture!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating:0,count:65536)
            while true { let count=stream.read(&buffer,maxLength:buffer.count); if count <= 0 { break }; body.append(contentsOf:buffer.prefix(count)) }
        }
        let result = Self.fixture.handle(request,body:body)
        if let error = result.error { client?.urlProtocol(self,didFailWithError:error); return }
        client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:result.code,httpVersion:nil,headerFields:result.headers)!,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:try! JSONSerialization.data(withJSONObject:result.json))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
