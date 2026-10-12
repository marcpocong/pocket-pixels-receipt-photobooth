import Foundation
import UIKit
import XCTest
@testable import PocketPixelsBooth

/// Phase 2 of the Made to Keep Studios migration: new sessions use the preferred Made to Keep
/// customer gallery front door, while legacy Pocket Pixels QR links, tokens, archives, recovery
/// snapshots and queued uploads keep the URL they were originally generated with.
///
/// `gallery.madetokeep.test` is a TEST-ONLY hostname; no production Made to Keep domain exists yet.
@MainActor
final class GalleryFrontDoorMigrationTests: XCTestCase {
    private let legacyBase = "https://pocket-pixels-gallery.pocketpixels-ceb.workers.dev/"
    private let madeToKeepBase = "https://gallery.madetokeep.test/"
    private let token = String(repeating: "e", count: 64)
    private let date = Date(timeIntervalSince1970: 1_788_692_040)

    // MARK: Configuration precedence

    func testMadeToKeepInfoPlistKeyIsPreferredOverLegacyKey() throws {
        let resolved = try CustomerGalleryConfiguration.resolve(operatorOverride: nil, infoPlistValue: infoPlist(madeToKeep: madeToKeepBase, legacy: legacyBase))
        XCTAssertEqual(resolved.source, .madeToKeepInfoPlist)
        XCTAssertEqual(resolved.configuration.baseURL.absoluteString, madeToKeepBase)
    }

    func testLegacyInfoPlistKeyRemainsFallback() throws {
        for blank in [nil, "", "   ", "$(MADE_TO_KEEP_CUSTOMER_GALLERY_BASE_URL)"] {
            let resolved = try CustomerGalleryConfiguration.resolve(operatorOverride: nil, infoPlistValue: infoPlist(madeToKeep: blank, legacy: legacyBase))
            XCTAssertEqual(resolved.source, .legacyInfoPlist, "Blank/unexpanded Made to Keep value \(String(describing: blank)) must fall back")
            XCTAssertEqual(resolved.configuration.baseURL.absoluteString, legacyBase)
        }
    }

    func testOperatorOverrideHasHighestPriority() throws {
        let resolved = try CustomerGalleryConfiguration.resolve(operatorOverride: legacyBase, infoPlistValue: infoPlist(madeToKeep: madeToKeepBase, legacy: legacyBase))
        XCTAssertEqual(resolved.source, .operatorOverride)
        XCTAssertEqual(resolved.configuration.baseURL.absoluteString, legacyBase, "Operators can still pin the legacy front door")

        let toNew = try CustomerGalleryConfiguration.resolve(operatorOverride: " \(madeToKeepBase) ", infoPlistValue: infoPlist(madeToKeep: nil, legacy: legacyBase))
        XCTAssertEqual(toNew.source, .operatorOverride)
        XCTAssertEqual(toNew.configuration.baseURL.absoluteString, madeToKeepBase)

        let blankOverride = try CustomerGalleryConfiguration.resolve(operatorOverride: "  ", infoPlistValue: infoPlist(madeToKeep: madeToKeepBase, legacy: legacyBase))
        XCTAssertEqual(blankOverride.source, .madeToKeepInfoPlist)
    }

    func testMissingBothKeysGivesClearError() {
        XCTAssertThrowsError(try CustomerGalleryConfiguration.resolve(operatorOverride: nil, infoPlistValue: infoPlist(madeToKeep: nil, legacy: nil))) { error in
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("MADE_TO_KEEP_CUSTOMER_GALLERY_BASE_URL"), message)
            XCTAssertTrue(message.contains("POCKET_PIXELS_CUSTOMER_GALLERY_BASE_URL"), message)
        }
    }

    func testInvalidPreferredValueFailsInsteadOfSilentlyFallingBack() {
        for invalid in ["http://gallery.madetokeep.test/", "https://script.google.com/macros/s/ABC/exec", "not a url"] {
            XCTAssertThrowsError(
                try CustomerGalleryConfiguration.resolve(operatorOverride: nil, infoPlistValue: infoPlist(madeToKeep: invalid, legacy: legacyBase)),
                "\(invalid) must be rejected"
            )
        }
    }

    func testValidationAcceptsLegacyAndMadeToKeepHostsAndStaysStrict() {
        XCTAssertNoThrow(try CustomerGalleryConfiguration.validate(rawValue: legacyBase))
        XCTAssertNoThrow(try CustomerGalleryConfiguration.validate(rawValue: madeToKeepBase))
        XCTAssertNoThrow(try CustomerGalleryConfiguration.validate(rawValue: "https://made-to-keep-gallery.example.workers.dev/"))
        XCTAssertThrowsError(try CustomerGalleryConfiguration.validate(rawValue: "http://gallery.madetokeep.test/"))
        XCTAssertThrowsError(try CustomerGalleryConfiguration.validate(rawValue: "https://script.google.com/macros/s/ABC/exec"))
        XCTAssertThrowsError(try CustomerGalleryConfiguration.validate(rawValue: ""))
    }

    func testOperatorOverrideStoreAcceptsBothFrontDoors() throws {
        let suiteName = "GalleryFrontDoorMigrationTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = GalleryBackendOverrideStore(defaults: defaults)
        for base in [legacyBase, madeToKeepBase] {
            try store.save(uploadURL: "", customerURL: base)
            XCTAssertEqual(store.customerURLOverride(), base)
            XCTAssertNil(store.uploadURLOverride(), "Customer front door override must not touch the upload URL")
        }
        XCTAssertThrowsError(try store.save(uploadURL: "", customerURL: "https://script.google.com/macros/s/ABC/exec"))
    }

    func testPackagedInfoPlistUsesVerifiedMadeToKeepFrontDoor() {
        let bundle = Bundle(for: BoothSessionViewModel.self)
        let preferred = (bundle.object(forInfoDictionaryKey: CustomerGalleryConfiguration.infoPlistKey) as? String) ?? ""
        XCTAssertEqual(preferred, "https://gallery.madetokeepstudios.workers.dev/")
        XCTAssertEqual(bundle.object(forInfoDictionaryKey: CustomerGalleryConfiguration.legacyInfoPlistKey) as? String, legacyBase)
        XCTAssertEqual(
            bundle.object(forInfoDictionaryKey: GoogleDriveGalleryConfiguration.infoPlistKey) as? String,
            "https://script.google.com/macros/s/AKfycbxFc4wpaRipbj-xEXt-zW6m5GoaJ1QkJtnw8Ryg4aH5rDeZDXXctXDTCWCWJwK1SwRSdQ/exec",
            "The Apps Script upload endpoint is unchanged by the front-door migration"
        )
    }

    // MARK: URL generation

    func testNewSessionsUsePreferredFrontDoorWithUnchangedQueryAndToken() throws {
        let preferred = try CustomerGalleryConfiguration.resolve(operatorOverride: nil, infoPlistValue: infoPlist(madeToKeep: madeToKeepBase, legacy: legacyBase)).configuration
        let url = try GalleryURLBuilder.makeGalleryURL(customerGalleryBaseURL: preferred.baseURL, galleryToken: token)
        XCTAssertEqual(url.absoluteString, "\(madeToKeepBase)?g=\(token)")
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems, [URLQueryItem(name: "g", value: token)])

        let legacy = try GalleryURLBuilder.makeGalleryURL(customerGalleryBaseURL: XCTUnwrap(URL(string: legacyBase)), galleryToken: token)
        XCTAssertEqual(legacy.absoluteString, "\(legacyBase)?g=\(token)")

        let minted = try GalleryTokenGenerator.makeGalleryToken()
        XCTAssertTrue(GalleryTokenGenerator.isValidGalleryToken(minted))
        XCTAssertEqual(minted.count, 64)
    }

    func testEveryBoothFormatComposesReceiptQRFromItsSessionURL() throws {
        let url = try GalleryURLBuilder.makeGalleryURL(customerGalleryBaseURL: XCTUnwrap(URL(string: madeToKeepBase)), galleryToken: token)
        for format in BoothFormat.allCases where format != .passport {
            let photos = (0..<format.photoCount).map { ReliabilityFixtures.syntheticPhoto(session: 900, photo: $0 + 1, format: format) }
            let receipt = try ReceiptComposer.compose(photos: photos, sessionIdentifier: "PP-20260907-090000", date: date, galleryURL: url, format: format)
            XCTAssertFalse(receipt.imagePNGData.isEmpty, "\(format) receipt")
        }
    }

    func testLoadUsesStandardOperatorOverrideForNewSessions() throws {
        let store = GalleryBackendOverrideStore()
        let previousUpload = store.uploadURLOverride()
        let previousCustomer = store.customerURLOverride()
        defer { try? store.save(uploadURL: previousUpload ?? "", customerURL: previousCustomer ?? "") }

        try store.save(uploadURL: previousUpload ?? "", customerURL: madeToKeepBase)
        let url = try GalleryURLBuilder.makeGalleryURL(customerGalleryBaseURL: CustomerGalleryConfiguration.load().baseURL, galleryToken: token)
        XCTAssertEqual(url.host(), "gallery.madetokeep.test")
        XCTAssertTrue(CustomerGalleryConfiguration.activeFrontDoorDescription().contains("gallery.madetokeep.test"))
    }

    func testGalleryURLRoundTripsToItsOwnFrontDoor() throws {
        for base in [legacyBase, madeToKeepBase, "https://gallery.madetokeep.test/path/"] {
            let baseURL = try XCTUnwrap(URL(string: base))
            let url = try GalleryURLBuilder.makeGalleryURL(customerGalleryBaseURL: baseURL, galleryToken: token)
            let recovered = try XCTUnwrap(GalleryURLBuilder.customerGalleryBaseURL(ofGalleryURL: url, galleryToken: token))
            XCTAssertEqual(try GalleryURLBuilder.makeGalleryURL(customerGalleryBaseURL: recovered, galleryToken: token), url)
        }
        let other = String(repeating: "f", count: 64)
        let legacyURL = try XCTUnwrap(URL(string: "\(legacyBase)?g=\(token)"))
        XCTAssertNil(GalleryURLBuilder.customerGalleryBaseURL(ofGalleryURL: legacyURL, galleryToken: other))
        XCTAssertNil(GalleryURLBuilder.customerGalleryBaseURL(ofGalleryURL: try XCTUnwrap(URL(string: "https://script.google.com/macros/s/ABC/exec?g=\(token)")), galleryToken: token))
        XCTAssertNil(GalleryURLBuilder.customerGalleryBaseURL(ofGalleryURL: try XCTUnwrap(URL(string: "http://gallery.madetokeep.test/?g=\(token)")), galleryToken: token))
    }

    // MARK: Upload response validation

    func testSuccessfulResponseFromEitherFrontDoorIsAcceptedForSameToken() throws {
        let legacyURL = try XCTUnwrap(URL(string: "\(legacyBase)?g=\(token)"))
        let newURL = try XCTUnwrap(URL(string: "\(madeToKeepBase)?g=\(token)"))
        for (expected, returned) in [(legacyURL, newURL), (newURL, legacyURL), (newURL, newURL), (legacyURL, legacyURL)] {
            XCTAssertTrue(GoogleDriveGalleryUploadService.validateSuccessfulResponse(
                try response(galleryURL: returned, token: token, photoCount: 2),
                expectedGalleryToken: token,
                expectedGalleryURL: expected,
                expectedPhotoCount: 2
            ))
        }
        let otherToken = String(repeating: "f", count: 64)
        let wrongToken = try XCTUnwrap(URL(string: "\(madeToKeepBase)?g=\(otherToken)"))
        XCTAssertFalse(GoogleDriveGalleryUploadService.validateSuccessfulResponse(try response(galleryURL: wrongToken, token: token, photoCount: 2), expectedGalleryToken: token, expectedGalleryURL: legacyURL, expectedPhotoCount: 2))
        let scriptURL = try XCTUnwrap(URL(string: "https://script.google.com/macros/s/ABC/exec?g=\(token)"))
        XCTAssertFalse(GoogleDriveGalleryUploadService.validateSuccessfulResponse(try response(galleryURL: scriptURL, token: token, photoCount: 2), expectedGalleryToken: token, expectedGalleryURL: legacyURL, expectedPhotoCount: 2))
    }

    // MARK: Pending queue

    func testQueuedLegacyAndNewPayloadsKeepTheirFrozenURLs() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let legacyToken = String(repeating: "1", count: 64)
        let newToken = String(repeating: "2", count: 64)
        let legacyPayload = try payload(token: legacyToken, base: legacyBase)
        let queue = try GalleryPendingUploadStore(directoryURL: directory)
        try queue.save(legacyPayload)

        // The app is later configured for the Made to Keep front door; a new session is queued.
        let service = GoogleDriveGalleryUploadService(
            customerGalleryConfigurationProvider: { try CustomerGalleryConfiguration.validate(rawValue: self.madeToKeepBase) },
            pendingStore: queue
        )
        let photos = (0..<2).map { ReliabilityFixtures.syntheticPhoto(session: 902, photo: $0 + 1, format: .duo) }
        let newPayload = try await service.prepareAndPersistGallery(photos: photos, composedReceipt: photos[0], sessionID: "PP-20260907-090002", createdAt: date, galleryToken: newToken)
        XCTAssertEqual(newPayload.galleryURL.absoluteString, "\(madeToKeepBase)?g=\(newToken)")

        let reopened = try GalleryPendingUploadStore(directoryURL: directory)
        XCTAssertEqual(try reopened.load(galleryToken: legacyToken)?.galleryURL.absoluteString, "\(legacyBase)?g=\(legacyToken)")
        XCTAssertEqual(try reopened.load(galleryToken: legacyToken)?.photos.map(\.data), legacyPayload.photos.map(\.data))
        XCTAssertEqual(try reopened.load(galleryToken: newToken)?.galleryURL.absoluteString, "\(madeToKeepBase)?g=\(newToken)")
    }

    func testPreparationReusesSessionFrozenURLEvenAfterConfigChanges() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        // Session minted under the legacy front door (QR already shown/printed); config now points
        // at Made to Keep before the gallery is prepared (e.g. recovery after an app update).
        let frozen = try XCTUnwrap(URL(string: "\(legacyBase)?g=\(token)"))
        let service = GoogleDriveGalleryUploadService(
            customerGalleryConfigurationProvider: { try CustomerGalleryConfiguration.validate(rawValue: self.madeToKeepBase) },
            pendingStore: try GalleryPendingUploadStore(directoryURL: directory)
        )
        let photos = [ReliabilityFixtures.syntheticPhoto(session: 903, photo: 1, format: .solo)]
        let prepared = try await service.prepareAndPersistGallery(photos: photos, composedReceipt: photos[0], sessionID: "PP-20260907-090003", createdAt: date, galleryToken: token, frozenGalleryURL: frozen)
        XCTAssertEqual(prepared.galleryURL, frozen)

        let mismatched = try XCTUnwrap(URL(string: "\(legacyBase)?g=\(String(repeating: "f", count: 64))"))
        do {
            _ = try await service.prepareAndPersistGallery(photos: photos, composedReceipt: photos[0], sessionID: "PP-20260907-090004", createdAt: date, galleryToken: token, frozenGalleryURL: mismatched)
            XCTFail("A frozen URL for a different token must be rejected")
        } catch {
            XCTAssertEqual(error as? GalleryUploadError, .invalidGalleryURL)
        }
    }

    func testRetryReturnsFrozenLegacyURLWhenBackendNowAnswersWithNewFrontDoor() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let legacyPayload = try payload(token: token, base: legacyBase)
        let queue = try GalleryPendingUploadStore(directoryURL: directory)
        try queue.save(legacyPayload)

        FrontDoorStubURLProtocol.responseBody = Data("""
        {"ok":true,"schemaVersion":2,"galleryToken":"\(token)","galleryURL":"\(madeToKeepBase)?g=\(token)","fileCount":\(legacyPayload.photos.count + 4),"status":"created"}
        """.utf8)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FrontDoorStubURLProtocol.self]
        let service = GoogleDriveGalleryUploadService(
            configurationProvider: { try GoogleDriveGalleryConfiguration.validate(rawValue: "https://script.google.com/macros/s/TEST_DEPLOYMENT/exec") },
            customerGalleryConfigurationProvider: { try CustomerGalleryConfiguration.validate(rawValue: self.madeToKeepBase) },
            urlSession: URLSession(configuration: configuration),
            pendingStore: queue
        )

        let result = try await service.uploadPendingGallery(galleryToken: token, deviceToken: String(repeating: "x", count: 32))
        XCTAssertEqual(result.galleryURL.absoluteString, "\(legacyBase)?g=\(token)", "Retry must not substitute the current front door for the printed one")
        XCTAssertEqual(result.galleryToken, token)
        XCTAssertNil(try queue.load(galleryToken: token), "Successful retry clears the queued payload")
    }

    // MARK: Recovery and archive

    func testRecoverySnapshotsRoundTripLegacyAndNewURLsUnchanged() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try AppRecoveryStore(directoryURL: directory)
        for base in [legacyBase, madeToKeepBase] {
            let url = try XCTUnwrap(URL(string: "\(base)?g=\(token)"))
            store.save(AppRecoverySnapshot(schemaVersion: 1, sessionIdentifier: "PP-FRONT-DOOR", createdAt: date, format: .duo, eventProfile: nil, galleryToken: token, galleryURL: url, photoJPEGData: [], receiptPreviewPNGData: nil, thermalPreviewPNGData: nil, rasterFingerprint: nil, stage: .receiptComposed, updatedAt: date))
            XCTAssertEqual(try AppRecoveryStore(directoryURL: directory).load()?.galleryURL, url)
        }
    }

    func testArchivedSessionsRetainOriginalURLAndReprintReproducesSameQR() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try RecentSessionArchiveStore(directoryURL: directory)
        let legacyToken = String(repeating: "3", count: 64)
        let newToken = String(repeating: "4", count: 64)
        var receipts: [String: ComposedReceipt] = [:]
        var committedByToken: [String: CommittedGallerySession] = [:]
        for (sessionToken, base, id) in [(legacyToken, legacyBase, "PP-20260907-090005"), (newToken, madeToKeepBase, "PP-20260907-090006")] {
            let url = try GalleryURLBuilder.makeGalleryURL(customerGalleryBaseURL: XCTUnwrap(URL(string: base)), galleryToken: sessionToken)
            let photos = (0..<2).map { ReliabilityFixtures.syntheticPhoto(session: 904, photo: $0 + 1, format: .duo) }
            let committed = CommittedGallerySession(sessionIdentifier: id, createdAt: date, galleryToken: sessionToken, galleryURL: url, photos: photos, format: .duo, eventProfile: nil)
            let receipt = try ReceiptComposer.compose(photos: photos, sessionIdentifier: id, date: date, galleryURL: url, format: .duo)
            let raster = try ThermalImageRasterizer.rasterize(XCTUnwrap(UIImage(data: receipt.imagePNGData)), purpose: .completeReceipt)
            try store.save(RecentSessionArchivePayload(committedSession: committed, composedReceipt: receipt, receiptPreviewPNGData: receipt.imagePNGData, thermalPreviewPNGData: raster.previewPNGData, rasterizedImage: raster, photoThumbnailData: [Data([1]), Data([2])]))
            receipts[sessionToken] = receipt
            committedByToken[sessionToken] = committed
        }

        let reopened = try RecentSessionArchiveStore(directoryURL: directory)
        XCTAssertEqual(try reopened.load(archiveID: legacyToken).galleryURL.absoluteString, "\(legacyBase)?g=\(legacyToken)")
        XCTAssertEqual(try reopened.load(archiveID: newToken).galleryURL.absoluteString, "\(madeToKeepBase)?g=\(newToken)")

        try reopened.markReprinted(archiveID: legacyToken, copies: 1)
        let legacyArchive = try RecentSessionArchiveStore(directoryURL: directory).load(archiveID: legacyToken)
        XCTAssertEqual(legacyArchive.galleryURL.host(), "pocket-pixels-gallery.pocketpixels-ceb.workers.dev", "Reprint must not rewrite the archived URL")
        let committed = try XCTUnwrap(committedByToken[legacyToken])
        let recomposed = try ReceiptComposer.compose(photos: committed.photos, sessionIdentifier: committed.sessionIdentifier, date: committed.createdAt, galleryURL: legacyArchive.galleryURL, format: .duo)
        XCTAssertEqual(recomposed.imagePNGData, receipts[legacyToken]?.imagePNGData, "Legacy reprint reproduces the same QR")
    }

    // MARK: Helpers

    private func infoPlist(madeToKeep: String?, legacy: String?) -> (String) -> Any? {
        { key in
            switch key {
            case CustomerGalleryConfiguration.infoPlistKey: madeToKeep
            case CustomerGalleryConfiguration.legacyInfoPlistKey: legacy
            default: nil
            }
        }
    }

    private func response(galleryURL: URL, token: String, photoCount: Int) throws -> GalleryUploadResponse {
        let json = """
        {"ok":true,"schemaVersion":2,"galleryToken":"\(token)","galleryURL":"\(galleryURL.absoluteString)","fileCount":\(photoCount + 4),"status":"created"}
        """
        return try JSONDecoder().decode(GalleryUploadResponse.self, from: Data(json.utf8))
    }

    private func payload(token: String, base: String) throws -> GalleryPreparedUploadPayload {
        let photos = (0..<2).map { ReliabilityFixtures.syntheticPhoto(session: 901, photo: $0 + 1, format: .duo) }
        return try GoogleDriveGalleryUploadService.preparePayload(
            photos: photos,
            composedReceipt: photos[0],
            sessionID: "PP-20260907-090001",
            createdAt: date,
            galleryToken: token,
            customerGalleryBaseURL: XCTUnwrap(URL(string: base))
        )
    }
}

/// Answers every request with a canned Apps Script success body.
private final class FrontDoorStubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var responseBody = Data()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseBody)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
