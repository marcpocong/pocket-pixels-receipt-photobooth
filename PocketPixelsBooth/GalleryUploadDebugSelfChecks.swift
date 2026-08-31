//
//  GalleryUploadDebugSelfChecks.swift
//  PocketPixelsBooth
//
//  Created by marc on 8/30/26.
//

#if DEBUG
import CoreImage
import Foundation
import UIKit

enum GalleryUploadDebugSelfChecks {
    @MainActor
    static func run() throws {
        try runCodeScopeSelfChecks()

        try assertThrows("placeholder URL") {
            _ = try GoogleDriveGalleryConfiguration.validate(rawValue: GoogleDriveGalleryConfiguration.placeholder)
        }

        try assertThrows("non-HTTPS URL") {
            _ = try GoogleDriveGalleryConfiguration.validate(rawValue: "http://script.google.com/macros/s/example/exec")
        }

        try assertThrows("development URL") {
            _ = try GoogleDriveGalleryConfiguration.validate(rawValue: "https://script.google.com/macros/s/example/dev")
        }

        try assertThrows("library URL") {
            _ = try GoogleDriveGalleryConfiguration.validate(rawValue: "https://script.google.com/macros/library/example/exec")
        }

        let canonicalConfiguration = try GoogleDriveGalleryConfiguration.validate(rawValue: "  https://script.google.com/macros/s/example/exec\n")
        guard canonicalConfiguration.webAppURL.absoluteString == "https://script.google.com/macros/s/example/exec" else {
            throw GalleryUploadError.invalidGalleryURL
        }

        let accountScopedConfiguration = try GoogleDriveGalleryConfiguration.validate(rawValue: "https://script.google.com/macros/u/2/s/example/exec")
        guard accountScopedConfiguration.webAppURL.absoluteString == "https://script.google.com/macros/s/example/exec" else {
            throw GalleryUploadError.invalidGalleryURL
        }

        let createdAtString = GalleryUploadDateFormatter.string(from: Date())
        guard GalleryUploadDateFormatter.isValidWireString(createdAtString),
              GalleryUploadDateFormatter.date(from: createdAtString) != nil,
              createdAtString.hasSuffix("Z"),
              !createdAtString.contains(".") else {
            throw GalleryUploadError.invalidDate
        }

        guard !GalleryUploadDateFormatter.isValidWireString("") else {
            throw GalleryUploadError.decoding("Empty createdAt self-check failed.")
        }

        let localeDate = DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .medium)
        guard !GalleryUploadDateFormatter.isValidWireString(localeDate) else {
            throw GalleryUploadError.decoding("Locale createdAt self-check failed.")
        }

        let image = makeImage()
        _ = try GoogleDriveGalleryConfiguration.load().webAppURL
        let customerGalleryBaseURL = try CustomerGalleryConfiguration.load().baseURL
        try runTimestampContractSelfChecks()
        let galleryToken = try GalleryTokenGenerator.makeGalleryToken()
        let secondGalleryToken = try GalleryTokenGenerator.makeGalleryToken()
        guard GalleryTokenGenerator.isValidGalleryToken(galleryToken),
              GalleryTokenGenerator.isValidGalleryToken(secondGalleryToken),
              galleryToken != secondGalleryToken,
              galleryToken.count == 64,
              galleryToken == galleryToken.lowercased() else {
            throw GalleryUploadError.invalidGalleryToken
        }

        let galleryURL = try GalleryURLBuilder.makeGalleryURL(customerGalleryBaseURL: customerGalleryBaseURL, galleryToken: galleryToken)
        guard GalleryURLBuilder.validateGalleryURL(galleryURL, customerGalleryBaseURL: customerGalleryBaseURL, galleryToken: galleryToken),
              let queryItems = URLComponents(url: galleryURL, resolvingAgainstBaseURL: false)?.queryItems,
              queryItems.count == 1,
              queryItems.filter({ $0.name == "g" && $0.value == galleryToken }).count == 1,
              galleryURL.host()?.lowercased() != "script.google.com" else {
            throw GalleryUploadError.invalidGalleryURL
        }

        try runCanonicalGalleryURLSelfChecks(galleryToken: galleryToken)

        let qrImage = try GalleryQRCodeGenerator.makeQRCodeImage(for: galleryURL)
        try validateQRCodeImage(qrImage)
        try runBoothFormatSelfChecks()
        try runPortraitProcessorSelfChecks()
        try runReceiptLayoutSelfChecks(photos: [image, image, image, image], galleryURL: galleryURL)
        try runReceiptLayoutReviewBuilderSelfChecks(photos: [image, image, image, image], galleryURL: galleryURL)

        try assertThrows("zero photo count") {
            _ = try GoogleDriveGalleryUploadService.makeRequestBody(
                photos: [],
                composedReceipt: image,
                sessionID: "PP-20260830-120000",
                createdAt: Date(),
                galleryToken: galleryToken,
                deviceToken: "abcdefghijklmnopqrstuvwxyz123456"
            )
        }

        try assertThrows("too many photos") {
            _ = try GoogleDriveGalleryUploadService.makeRequestBody(
                photos: [image, image, image, image, image],
                composedReceipt: image,
                sessionID: "PP-20260830-120000",
                createdAt: Date(),
                galleryToken: galleryToken,
                deviceToken: "abcdefghijklmnopqrstuvwxyz123456"
            )
        }

        let request = try GoogleDriveGalleryUploadService.makeRequestBody(
            photos: [image, image, image, image],
            composedReceipt: image,
            sessionID: "PP-20260830-120000",
            createdAt: Date(),
            galleryToken: galleryToken,
            deviceToken: "abcdefghijklmnopqrstuvwxyz123456"
        )

        guard request.photos.count == 4,
              request.galleryToken == galleryToken,
              request.photos.map(\.filename) == ["photo-01.jpg", "photo-02.jpg", "photo-03.jpg", "photo-04.jpg"],
              request.receipt.filename == "receipt-color.jpg",
              request.photos.allSatisfy({ $0.base64Data.data(using: .utf8)?.count ?? 0 > 0 }),
              GoogleDriveGalleryUploadService.validateNoDisallowedFields(in: request) else {
            throw GalleryUploadError.decoding("Payload self-check failed.")
        }

        let payload = try GoogleDriveGalleryUploadService.preparePayload(
            photos: [image, image, image, image],
            composedReceipt: image,
            sessionID: "PP-20260830-120000",
            createdAt: Date(),
            galleryToken: galleryToken,
            customerGalleryBaseURL: customerGalleryBaseURL
        )

        guard payload.metrics.files.count == 5,
              payload.galleryToken == galleryToken,
              payload.galleryURL == galleryURL,
              payload.metrics.files.allSatisfy({ $0.decodedBytes <= GalleryPreparedUploadMetrics.maxFileDecodedBytes }),
              payload.metrics.totalDecodedBytes <= GalleryPreparedUploadMetrics.maxTotalDecodedBytes,
              payload.metrics.estimatedBase64JSONBytes <= GalleryPreparedUploadMetrics.maxEstimatedBase64JSONBytes else {
            throw GalleryUploadError.requestTooLarge("Image byte limit self-check failed.")
        }

        let requestData = try JSONEncoder().encode(request)
        guard let jsonObject = try JSONSerialization.jsonObject(with: requestData) as? [String: Any],
              requiredRequestKeysExist(in: jsonObject),
              let jsonCreatedAt = jsonObject["createdAt"] as? String,
              let jsonGalleryToken = jsonObject["galleryToken"] as? String,
              let jsonSessionID = jsonObject["sessionID"] as? String,
              let jsonPhotos = jsonObject["photos"] as? [[String: Any]],
              let jsonReceipt = jsonObject["receipt"] as? [String: Any],
              jsonCreatedAt == request.createdAt,
              jsonGalleryToken == galleryToken,
              jsonGalleryToken.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil,
              jsonSessionID.range(of: #"^PP-[0-9]{8}-[0-9]{6}$"#, options: .regularExpression) != nil,
              GalleryUploadDateFormatter.isValidWireString(jsonCreatedAt),
              jsonPhotos.count == 4,
              jsonPhotos.enumerated().allSatisfy({ index, photo in photo["filename"] as? String == String(format: "photo-%02d.jpg", index + 1) }),
              jsonReceipt["filename"] as? String == "receipt-color.jpg",
              !(jsonObject["createdAt"] is NSNumber) else {
            throw GalleryUploadError.decoding("Outbound JSON string self-check failed.")
        }

        let decodedRequest = try JSONDecoder().decode(GalleryUploadRequest.self, from: requestData)
        guard decodedRequest.galleryToken == request.galleryToken,
              decodedRequest.sessionID == request.sessionID,
              decodedRequest.createdAt == request.createdAt,
              decodedRequest.photos.map(\.filename) == request.photos.map(\.filename),
              decodedRequest.receipt.filename == request.receipt.filename else {
            throw GalleryUploadError.decoding("Request JSON round-trip self-check failed.")
        }

        let diagnostics = GoogleDriveGalleryUploadService.makeSanitizedRequestDiagnostics(request, encodedBody: requestData)
        guard diagnostics.hasDeviceToken,
              diagnostics.galleryTokenCharacterCount == 64,
              diagnostics.galleryTokenMatchesLowercaseHex,
              diagnostics.photoCount == 4,
              diagnostics.photoFilenames == ["photo-01.jpg", "photo-02.jpg", "photo-03.jpg", "photo-04.jpg"],
              !diagnostics.description.contains(request.deviceToken),
              !diagnostics.description.contains(request.galleryToken),
              !request.photos.contains(where: { diagnostics.description.contains($0.base64Data) }) else {
            throw GalleryUploadError.decoding("Sanitized request diagnostics self-check failed.")
        }

        let responseJSON = """
        {"ok":true,"schemaVersion":1,"galleryToken":"\(galleryToken)","galleryURL":"\(galleryURL.absoluteString)","fileCount":6,"status":"existingComplete"}
        """
        let response = try JSONDecoder().decode(GalleryUploadResponse.self, from: Data(responseJSON.utf8))
        guard response.ok,
              response.galleryToken == galleryToken,
              response.fileCount == 6,
              GalleryUploadResultStatus(serverStatus: response.status) == .existingComplete,
              GoogleDriveGalleryUploadService.validateSuccessfulResponse(
                response,
                expectedGalleryToken: galleryToken,
                expectedGalleryURL: galleryURL,
                expectedPhotoCount: 4
        ) else {
            throw GalleryUploadError.decoding("Response self-check failed.")
        }

        for photoCount in BoothConfiguration.minimumPhotosPerSession...BoothConfiguration.maximumPhotosPerSession {
            let completionResponse = GalleryUploadResponse(
                ok: true,
                schemaVersion: 1,
                galleryToken: galleryToken,
                galleryURL: galleryURL,
                fileCount: photoCount + 2,
                errorCode: nil,
                error: nil,
                status: "created",
                field: nil,
                stage: nil,
                detail: nil
            )
            guard GoogleDriveGalleryUploadService.validateSuccessfulResponse(
                completionResponse,
                expectedGalleryToken: galleryToken,
                expectedGalleryURL: galleryURL,
                expectedPhotoCount: photoCount
            ) else {
                throw GalleryUploadError.decoding("Variable completion count self-check failed.")
            }
        }

        let conflictResponseJSON = """
        {"ok":false,"schemaVersion":1,"error":"Gallery token belongs to a different or conflicting session.","status":"conflict"}
        """
        let conflictResponse = try JSONDecoder().decode(GalleryUploadResponse.self, from: Data(conflictResponseJSON.utf8))
        guard !conflictResponse.ok, conflictResponse.status == "conflict" else {
            throw GalleryUploadError.decoding("Conflict response self-check failed.")
        }

        let malformedResponseJSON = """
        {"ok":false,"schemaVersion":1,"errorCode":"INVALID_GALLERY_TOKEN","error":"Invalid gallery token.","field":"galleryToken","status":"rejected"}
        """
        let malformedResponse = try JSONDecoder().decode(GalleryUploadResponse.self, from: Data(malformedResponseJSON.utf8))
        guard !malformedResponse.ok,
              malformedResponse.errorCode == "INVALID_GALLERY_TOKEN",
              malformedResponse.error == "Invalid gallery token." else {
            throw GalleryUploadError.decoding("Safe validation error response self-check failed.")
        }

        let diagnosticResponseJSON = """
        {"ok":true,"schemaVersion":1,"backendVersion":"phase6c-worker-raw-html-proxy-20260831","galleryTokenPattern":"lowercase-hex-64","canonicalURLPolicy":true,"accountScopedPathAllowed":false,"status":"diagnostic"}
        """
        let diagnosticResponse = try JSONDecoder().decode(GalleryBackendDiagnosticResponse.self, from: Data(diagnosticResponseJSON.utf8))
        guard diagnosticResponse.ok,
              diagnosticResponse.backendVersion == "phase6c-worker-raw-html-proxy-20260831" else {
            throw GalleryUploadError.decoding("Backend diagnostic response self-check failed.")
        }

        let invalidResponseJSON = """
        {"ok":true,"schemaVersion":1,"galleryToken":"\(galleryToken)","galleryURL":"\(galleryURL.absoluteString)","fileCount":4,"status":"created"}
        """
        let invalidResponse = try JSONDecoder().decode(GalleryUploadResponse.self, from: Data(invalidResponseJSON.utf8))
        guard !GoogleDriveGalleryUploadService.validateSuccessfulResponse(invalidResponse) else {
            throw GalleryUploadError.invalidResponse
        }

        let noInternet = GalleryNetworkClassifier.classify(
            urlError: URLError(.notConnectedToInternet),
            fallbackHost: "script.google.com"
        )
        guard case .wifiNoUsableInternet(let noInternetHost, let noInternetCode) = noInternet,
              noInternetHost == "script.google.com",
              noInternetCode == URLError.Code.notConnectedToInternet.rawValue else {
            throw GalleryUploadError.network("No-internet classification self-check failed.")
        }

        let timeout = GalleryNetworkClassifier.classify(
            urlError: URLError(.timedOut),
            fallbackHost: "script.google.com"
        )
        guard case .timeout(_, let timeoutCode) = timeout,
              timeoutCode == URLError.Code.timedOut.rawValue else {
            throw GalleryUploadError.timeout
        }

        let tls = GalleryNetworkClassifier.classify(
            urlError: URLError(.secureConnectionFailed),
            fallbackHost: "script.google.com"
        )
        guard case .tlsFailure(_, let tlsCode) = tls,
              tlsCode == URLError.Code.secureConnectionFailed.rawValue else {
            throw GalleryUploadError.network("TLS classification self-check failed.")
        }

        let deliveryUnknownDescription = GalleryUploadError.deliveryUnknown.localizedDescription
        guard deliveryUnknownDescription.contains("server may have received"),
              !deliveryUnknownDescription.localizedCaseInsensitiveContains("automatic") else {
            throw GalleryUploadError.deliveryUnknown
        }

        guard GalleryUploadError.uploadAlreadyActive.localizedDescription.contains("already active") else {
            throw GalleryUploadError.uploadAlreadyActive
        }

        let retryPayload = GalleryPreparedUploadPayload(
            schemaVersion: payload.schemaVersion,
            galleryToken: payload.galleryToken,
            galleryURL: payload.galleryURL,
            sessionID: payload.sessionID,
            createdAt: payload.createdAt,
            photos: payload.photos,
            receipt: payload.receipt,
            metrics: payload.metrics,
            deliveryState: .deliveryUnknown
        )
        guard retryPayload.galleryToken == payload.galleryToken,
              retryPayload.sessionID == payload.sessionID else {
            throw GalleryUploadError.decoding("Retry token/session preservation self-check failed.")
        }

        try runPendingPayloadSelfChecks(payload: payload)
        try runLegacyPendingSelfCheck(payload: payload)
        try runSessionIsolationSelfChecks()
        try runSecretDiagnosticSelfChecks()
        debugLog("Gallery upload DEBUG self-checks passed.")
    }

    private static func assertThrows(_ name: String, operation: () throws -> Void) throws {
        do {
            try operation()
        } catch {
            return
        }

        throw GalleryUploadError.decoding("Expected self-check to throw for \(name).")
    }

    private static func runCanonicalGalleryURLSelfChecks(galleryToken: String) throws {
        let canonical = URL(string: "https://script.google.com/macros/s/ABC/exec")!
        let scopedInputs = [
            "https://script.google.com/macros/u/0/s/ABC/exec",
            "https://script.google.com/macros/u/1/s/ABC/exec",
            "https://script.google.com/macros/u/2/s/ABC/exec",
            "https://script.google.com/macros/u/10/s/ABC/exec"
        ]

        guard try GalleryURLBuilder.canonicalWebAppURL(canonical) == canonical else {
            throw GalleryUploadError.invalidGalleryURL
        }

        for rawValue in scopedInputs {
            guard let url = URL(string: rawValue),
                  try GalleryURLBuilder.canonicalWebAppURL(url) == canonical else {
                throw GalleryUploadError.invalidGalleryURL
            }
        }

        let customerBaseURL = URL(string: "https://pocket-pixels-gallery.pocketpixels-ceb.workers.dev/")!
        let generated = try GalleryURLBuilder.makeGalleryURL(
            customerGalleryBaseURL: customerBaseURL,
            galleryToken: galleryToken
        )
        let queryItems = URLComponents(url: generated, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard generated.scheme == "https",
              generated.absoluteString == "https://pocket-pixels-gallery.pocketpixels-ceb.workers.dev/?g=\(galleryToken)",
              generated.host()?.lowercased() != "script.google.com",
              queryItems.filter({ $0.name == "g" && $0.value == galleryToken }).count == 1,
              GalleryURLBuilder.validateGalleryURL(generated, customerGalleryBaseURL: customerBaseURL, galleryToken: galleryToken) else {
            throw GalleryUploadError.invalidGalleryURL
        }
    }

    @MainActor
    private static func makeImage(size: CGSize = CGSize(width: 64, height: 48)) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor.black.setFill()
            context.fill(CGRect(x: size.width * 0.125, y: size.height * 0.167, width: size.width * 0.75, height: size.height * 0.667))
        }
    }

    private static func runPendingPayloadSelfChecks(payload: GalleryPreparedUploadPayload) throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PocketPixelsGalleryPendingSelfCheck-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }

        let store = try GalleryPendingUploadStore(directoryURL: rootURL.appendingPathComponent("PendingGalleryUpload", isDirectory: true))
        try store.save(payload)
        try store.save(payload)

        guard let firstLoad = try store.load(),
              firstLoad == payload,
              let firstSummary = try store.summary(),
              firstSummary.sessionID == payload.sessionID,
              firstSummary.galleryToken == payload.galleryToken,
              firstSummary.galleryURL == payload.galleryURL else {
            throw GalleryUploadError.decoding("Pending payload atomic persistence self-check failed.")
        }

        let conflictingPhoto = GalleryStoredUploadImage(
            filename: payload.photos[0].filename,
            mimeType: payload.photos[0].mimeType,
            data: payload.photos[0].data + Data([0x01])
        )
        let conflictingPayload = GalleryPreparedUploadPayload(
            schemaVersion: payload.schemaVersion,
            galleryToken: payload.galleryToken,
            galleryURL: payload.galleryURL,
            sessionID: payload.sessionID,
            createdAt: payload.createdAt,
            photos: [conflictingPhoto] + Array(payload.photos.dropFirst()),
            receipt: payload.receipt,
            metrics: payload.metrics,
            deliveryState: payload.deliveryState
        )
        try assertThrows("conflicting pending gallery save") {
            try store.save(conflictingPayload)
        }
        guard let preservedPayload = try store.load(), preservedPayload == payload else {
            throw GalleryUploadError.conflictManualInspection("Conflicting save did not preserve existing pending payload.")
        }

        let relaunchedStore = try GalleryPendingUploadStore(directoryURL: rootURL.appendingPathComponent("PendingGalleryUpload", isDirectory: true))
        guard let relaunchedPayload = try relaunchedStore.load(),
              relaunchedPayload == payload else {
            throw GalleryUploadError.decoding("Pending payload relaunch self-check failed.")
        }

        try relaunchedStore.updateDeliveryState(.deliveryUnknown)
        guard let unknownPayload = try relaunchedStore.load(),
              unknownPayload.deliveryState == .deliveryUnknown else {
            throw GalleryUploadError.deliveryUnknown
        }

        let failedResponse = GalleryUploadResponse(
            ok: true,
            schemaVersion: 1,
            galleryToken: payload.galleryToken,
            galleryURL: payload.galleryURL,
            fileCount: 4,
            errorCode: nil,
            error: nil,
            status: "created",
            field: nil,
            stage: nil,
            detail: nil
        )
        guard !GoogleDriveGalleryUploadService.validateSuccessfulResponse(failedResponse),
              (try relaunchedStore.load()) != nil else {
            throw GalleryUploadError.invalidResponse
        }

        let successResponse = GalleryUploadResponse(
            ok: true,
            schemaVersion: 1,
            galleryToken: payload.galleryToken,
            galleryURL: payload.galleryURL,
            fileCount: 5,
            errorCode: nil,
            error: nil,
            status: "created",
            field: nil,
            stage: nil,
            detail: nil
        )
        guard GoogleDriveGalleryUploadService.validateSuccessfulResponse(successResponse) else {
            throw GalleryUploadError.invalidResponse
        }

        let unknownSuccessResponse = GalleryUploadResponse(
            ok: true,
            schemaVersion: 1,
            galleryToken: payload.galleryToken,
            galleryURL: payload.galleryURL,
            fileCount: 5,
            errorCode: nil,
            error: nil,
            status: "unexpectedSuccess",
            field: nil,
            stage: nil,
            detail: nil
        )
        guard !GoogleDriveGalleryUploadService.validateSuccessfulResponse(unknownSuccessResponse),
              (try relaunchedStore.load()) != nil else {
            throw GalleryUploadError.invalidResponse
        }

        let metadataURL = rootURL
            .appendingPathComponent("PendingGalleryUpload", isDirectory: true)
            .appendingPathComponent(payload.galleryToken, isDirectory: true)
            .appendingPathComponent("metadata.json")
        let currentMetadata = try String(contentsOf: metadataURL, encoding: .utf8)
        let oldGalleryURL = "https://gallery.example.com/?g=\(payload.galleryToken)"
        let oldMetadata = currentMetadata.replacingOccurrences(of: payload.galleryURL.absoluteString, with: oldGalleryURL)
        try Data(oldMetadata.utf8).write(to: metadataURL, options: .atomic)

        guard let migratedPayload = try relaunchedStore.load(galleryToken: payload.galleryToken),
              migratedPayload.galleryToken == payload.galleryToken,
              migratedPayload.galleryURL == payload.galleryURL,
              migratedPayload.sessionID == payload.sessionID,
              migratedPayload.createdAt == payload.createdAt,
              migratedPayload.photos.map(\.filename) == payload.photos.map(\.filename),
              migratedPayload.receipt.filename == payload.receipt.filename else {
            throw GalleryUploadError.invalidGalleryURL
        }

        try relaunchedStore.clear()
        guard try relaunchedStore.load() == nil else {
            throw GalleryUploadError.decoding("Pending payload clear self-check failed.")
        }
    }

    private static func runSecretDiagnosticSelfChecks() throws {
        let token = "abcdefghijklmnopqrstuvwxyz123456"
        let base64 = Data(repeating: 7, count: 24).base64EncodedString()
        let descriptions = [
            GalleryBackendConnectivityState.wifiNoUsableInternet(host: "script.google.com", code: -1009).diagnosticDescription,
            GalleryBackendConnectivityState.timeout(host: "script.google.com", code: -1001).diagnosticDescription,
            GalleryBackendConnectivityState.tlsFailure(host: "script.google.com", code: -1200).diagnosticDescription,
            GalleryUploadError.deliveryUnknown.localizedDescription,
            GalleryUploadError.pendingNoInternet.localizedDescription
        ]

        guard descriptions.allSatisfy({ !$0.contains(token) && !$0.contains(base64) }) else {
            throw GalleryUploadError.network("Secret diagnostic self-check failed.")
        }
    }

    private static func runSessionIsolationSelfChecks() throws {
        let tokenA = String(repeating: "a", count: 64)
        let tokenB = String(repeating: "b", count: 64)

        guard GalleryUploadSessionIsolationPolicy.canStartPreparation(
            activeTaskTokens: [tokenA],
            newGalleryToken: tokenB
        ) else {
            throw GalleryUploadError.uploadAlreadyActive
        }

        guard !GalleryUploadSessionIsolationPolicy.canStartPreparation(
            activeTaskTokens: [tokenA],
            newGalleryToken: tokenA
        ) else {
            throw GalleryUploadError.decoding("Duplicate same-token upload preparation was not suppressed.")
        }

        guard !GalleryUploadSessionIsolationPolicy.shouldApplyEvent(
            eventGalleryToken: tokenA,
            currentGalleryToken: tokenB
        ) else {
            throw GalleryUploadError.decoding("Older gallery failure could mutate the current customer.")
        }

        guard !GalleryUploadSessionIsolationPolicy.shouldApplyEvent(
            eventGalleryToken: tokenA,
            currentGalleryToken: tokenB
        ) else {
            throw GalleryUploadError.decoding("Older gallery success could mutate the current customer.")
        }

        guard GalleryUploadSessionIsolationPolicy.shouldApplyEvent(
            eventGalleryToken: tokenB,
            currentGalleryToken: tokenB
        ) else {
            throw GalleryUploadError.decoding("Current gallery event was incorrectly filtered.")
        }
    }

    private static func requiredRequestKeysExist(in object: [String: Any]) -> Bool {
        let keys = Set(object.keys)
        return keys.isSuperset(of: ["schemaVersion", "deviceToken", "galleryToken", "sessionID", "createdAt", "photos", "receipt"])
    }

    private static func runLegacyPendingSelfCheck(payload: GalleryPreparedUploadPayload) throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PocketPixelsGalleryLegacyPendingSelfCheck-\(UUID().uuidString)", isDirectory: true)
        let pendingURL = rootURL.appendingPathComponent("PendingGalleryUpload", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }

        try FileManager.default.createDirectory(at: pendingURL, withIntermediateDirectories: true)
        let legacyMetadata = """
        {"schemaVersion":1,"sessionID":"PP-20260830-120000","createdAt":"2026-08-30T12:00:00Z","photoFilenames":["photo-01.jpg","photo-02.jpg","photo-03.jpg"],"receiptFilename":"receipt-color.jpg","metrics":{"files":[],"totalDecodedBytes":0,"estimatedBase64JSONBytes":0},"deliveryState":"notStarted"}
        """
        try Data(legacyMetadata.utf8).write(to: pendingURL.appendingPathComponent("metadata.json"), options: .atomic)
        let store = try GalleryPendingUploadStore(directoryURL: pendingURL)
        guard store.hasLegacyPendingUpload() else {
            throw GalleryUploadError.stalePendingUpload
        }

        try store.save(payload)
        guard let summary = try store.summary(),
              summary.galleryToken == payload.galleryToken,
              let loadedPayload = try store.load(),
              loadedPayload == payload,
              FileManager.default.fileExists(atPath: pendingURL.appendingPathComponent("metadata.json").path) else {
            throw GalleryUploadError.decoding("Legacy pending data blocked valid V3 queue processing.")
        }
    }

    @MainActor
    private static func runTimestampContractSelfChecks() throws {
        let instant = makeUTCDate(year: 2026, month: 8, day: 30, hour: 17, minute: 44, second: 15)
        let sessionID = ReceiptComposer.makeSessionIdentifier(date: instant)
        let createdAt = GalleryUploadDateFormatter.string(from: instant)
        guard sessionID == "PP-20260831-014415",
              createdAt == "2026-08-30T17:44:15Z",
              dateFromManilaSessionIdentifier(sessionID) == instant,
              GalleryUploadDateFormatter.date(from: createdAt) == instant else {
            throw GalleryUploadError.invalidDate
        }

        let sameDateInstant = makeUTCDate(year: 2026, month: 8, day: 30, hour: 8, minute: 15, second: 30)
        let sameDateSessionID = ReceiptComposer.makeSessionIdentifier(date: sameDateInstant)
        let sameDateCreatedAt = GalleryUploadDateFormatter.string(from: sameDateInstant)
        guard sameDateSessionID == "PP-20260830-161530",
              sameDateCreatedAt == "2026-08-30T08:15:30Z",
              dateFromManilaSessionIdentifier(sameDateSessionID) == sameDateInstant,
              GalleryUploadDateFormatter.date(from: sameDateCreatedAt) == sameDateInstant,
              !createdAt.contains("."),
              !sameDateCreatedAt.contains("."),
              sessionID.count == "PP-yyyyMMdd-HHmmss".count,
              sameDateSessionID.count == "PP-yyyyMMdd-HHmmss".count else {
            throw GalleryUploadError.decoding("UTC/local midnight boundary self-check failed.")
        }
    }

    private static func makeUTCDate(year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int) -> Date {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        return components.date!
    }

    private static func dateFromManilaSessionIdentifier(_ sessionID: String) -> Date? {
        let prefix = "PP-"
        guard sessionID.hasPrefix(prefix) else {
            return nil
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Manila") ?? TimeZone(secondsFromGMT: 8 * 60 * 60)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.date(from: String(sessionID.dropFirst(prefix.count)))
    }

    private static func validateQRCodeImage(_ image: UIImage) throws {
        guard let cgImage = image.cgImage,
              cgImage.width >= GalleryQRCodeGenerator.pixelSize,
              cgImage.height >= GalleryQRCodeGenerator.pixelSize else {
            throw GalleryUploadError.qrGeneration("QR image is not large enough.")
        }

        let quietZonePoint = CGPoint(x: 2, y: 2)
        guard let provider = cgImage.dataProvider,
              let data = provider.data,
              let bytes = CFDataGetBytePtr(data),
              isOpaquePixel(bytes: bytes, image: cgImage, point: quietZonePoint),
              isWhitePixel(bytes: bytes, image: cgImage, point: quietZonePoint) else {
            throw GalleryUploadError.qrGeneration("QR quiet zone self-check failed.")
        }
    }

    @MainActor
    private static func runReceiptLayoutSelfChecks(photos: [UIImage], galleryURL: URL) throws {
        for format in BoothFormat.allCases {
            let plan = try ReceiptComposer.makeLayoutPlan(format: format)
            guard plan.width == BoothConfiguration.receiptWidth,
                  plan.height <= BoothConfiguration.receiptMaximumHeight,
                  plan.qrSize == ReceiptComposer.receiptQRCodeSize,
                  plan.displayedPhotoIndexes == Array(0..<format.photoCount),
                  plan.photoFrames.count == format.photoCount,
                  plan.photoFrames.allSatisfy({ Int($0.rect.width) * 4 == Int($0.rect.height) * 3 }) else {
                throw GalleryUploadError.decoding("Receipt layout plan self-check failed for \(format.displayName).")
            }

            try validateFormatSpecificReceiptPlan(plan)

            try runReceiptQRCodeSelfCheck(photos: Array(photos.prefix(format.photoCount)), galleryURL: galleryURL, format: format)
        }
    }

    private static func validateFormatSpecificReceiptPlan(_ plan: ReceiptLayoutPlan) throws {
        switch plan.format {
        case .strip:
            guard plan.photoFrames.map(\.photoIndex) == [0, 1, 2],
                  plan.photoFrames.allSatisfy({ Int($0.rect.width) == 240 && Int($0.rect.height) == 320 }),
                  plan.groupFrame != nil,
                  !plan.displayedPhotoIndexes.contains(3) else {
                throw GalleryUploadError.decoding("Strip geometry self-check failed.")
            }
        case .solo, .duo, .grid:
            break
        }
    }

    @MainActor
    private static func runReceiptQRCodeSelfCheck(
        photos: [UIImage],
        galleryURL: URL,
        format: BoothFormat
    ) throws {
        let receipt = try ReceiptComposer.compose(
            photos: photos,
            sessionIdentifier: "PP-20260830-120000",
            date: makeUTCDate(year: 2026, month: 8, day: 30, hour: 12, minute: 0, second: 0),
            galleryURL: galleryURL,
            format: format
        )
        guard receipt.width == BoothConfiguration.receiptWidth,
              receipt.height <= BoothConfiguration.receiptMaximumHeight,
              receipt.format == format,
              let image = UIImage(data: receipt.imagePNGData) else {
            throw GalleryUploadError.qrGeneration("Receipt QR dimensions self-check failed.")
        }

        let rasterized = try ThermalImageRasterizer.rasterize(image, purpose: .completeReceipt)
        try ThermalImageRasterizer.validateRasterCommand(
            rasterized.rasterCommand,
            imageWidth: rasterized.width,
            imageHeight: rasterized.height,
            bytesPerRow: rasterized.widthBytes,
            rasterDataCount: rasterized.rasterData.count
        )

        guard let cgImage = image.cgImage else {
            throw GalleryUploadError.qrGeneration("Receipt QR image could not be read.")
        }
        let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
        let ciImage = CIImage(cgImage: cgImage)
        let messages = detector?.features(in: ciImage).compactMap { ($0 as? CIQRCodeFeature)?.messageString } ?? []
        guard messages.contains(galleryURL.absoluteString) else {
            throw GalleryUploadError.qrGeneration("Receipt QR did not decode to the expected gallery URL.")
        }

        guard let thermalPreview = UIImage(data: rasterized.previewPNGData),
              let thermalCGImage = thermalPreview.cgImage else {
            throw GalleryUploadError.qrGeneration("Thermal receipt preview could not be read.")
        }
        let thermalMessages = detector?.features(in: CIImage(cgImage: thermalCGImage)).compactMap { ($0 as? CIQRCodeFeature)?.messageString } ?? []
        guard thermalMessages.contains(galleryURL.absoluteString) else {
            throw GalleryUploadError.qrGeneration("Thermal receipt preview QR did not decode to the expected gallery URL.")
        }

        let rebuiltReceipt = try ReceiptComposer.compose(
            photos: photos,
            sessionIdentifier: receipt.sessionIdentifier,
            date: receipt.createdAt,
            galleryURL: galleryURL,
            format: receipt.format
        )
        guard rebuiltReceipt.width == receipt.width,
              rebuiltReceipt.height == receipt.height,
              rebuiltReceipt.format == receipt.format else {
            throw GalleryUploadError.decoding("Receipt rebuild layout self-check failed.")
        }
    }

    private static func runBoothFormatSelfChecks() throws {
        guard BoothFormat.allCases.count == 4,
              BoothFormat.allCases == [.solo, .duo, .grid, .strip],
              BoothFormat.solo.photoCount == 1,
              BoothFormat.duo.photoCount == 2,
              BoothFormat.grid.photoCount == 4,
              BoothFormat.strip.photoCount == 3 else {
            throw GalleryUploadError.decoding("Booth format photo count self-check failed.")
        }
    }

    private static func runPortraitProcessorSelfChecks() throws {
        let sources = [
            makeImage(size: CGSize(width: 160, height: 90)),
            makeImage(size: CGSize(width: 90, height: 160)),
            makeImage(size: CGSize(width: 120, height: 120))
        ]

        for source in sources {
            let processed = BoothPhotoProcessor.normalizedPortraitPhoto(from: source)
            guard Int(processed.size.width) * 4 == Int(processed.size.height) * 3 else {
                throw GalleryUploadError.imageEncoding("Portrait crop self-check failed.")
            }
        }
    }

    @MainActor
    private static func runReceiptLayoutReviewBuilderSelfChecks(photos: [UIImage], galleryURL: URL) throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PocketPixelsReceiptLayoutReviewSelfCheck-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }

        let store = try GalleryPendingUploadStore(directoryURL: rootURL)
        let previews = try DebugReceiptLayoutReviewBuilder.makePreviews(photos: photos, galleryURL: galleryURL)

        let expectedCounts: [BoothFormat: Int] = [
            .solo: 1,
            .duo: 2,
            .grid: 4,
            .strip: 3
        ]

        guard previews.map(\.format) == [.solo, .duo, .grid, .strip],
              previews.count == BoothFormat.allCases.count,
              previews.allSatisfy({ $0.receipt.width == BoothConfiguration.receiptWidth }),
              previews.allSatisfy({ $0.receipt.format.photoCount == expectedCounts[$0.format] }),
              try store.summaries().isEmpty else {
            throw GalleryUploadError.decoding("Receipt layout review builder self-check failed.")
        }
    }

    private static func isWhitePixel(bytes: UnsafePointer<UInt8>, image: CGImage, point: CGPoint) -> Bool {
        let bytesPerPixel = max(1, image.bitsPerPixel / 8)
        let offset = (Int(point.y) * image.bytesPerRow) + (Int(point.x) * bytesPerPixel)
        return bytes[offset] > 240 && bytes[offset + min(1, bytesPerPixel - 1)] > 240 && bytes[offset + min(2, bytesPerPixel - 1)] > 240
    }

    private static func isOpaquePixel(bytes: UnsafePointer<UInt8>, image: CGImage, point: CGPoint) -> Bool {
        let bytesPerPixel = max(1, image.bitsPerPixel / 8)
        guard bytesPerPixel >= 4 else {
            return true
        }

        let offset = (Int(point.y) * image.bytesPerRow) + (Int(point.x) * bytesPerPixel)
        return bytes[offset + 3] == 255
    }

    private static func runCodeScopeSelfChecks() throws {
        guard FileManager.default.fileExists(atPath: "Backend/GoogleAppsScript/Code.gs") else {
            return
        }

        let code = try String(contentsOfFile: "Backend/GoogleAppsScript/Code.gs", encoding: .utf8)
        let forbiddenBackendAPIs = ["setTrashed", "deleteFile", "removeFile"]
        guard !forbiddenBackendAPIs.contains(where: { code.contains($0) }) else {
            throw GalleryUploadError.decoding("Code.gs contains an automatic Drive deletion API.")
        }

        guard !code.contains("INVALID_UPLOAD_REQUEST") else {
            throw GalleryUploadError.decoding("Code.gs can still emit INVALID_UPLOAD_REQUEST.")
        }

        let untouchedFiles = [
            "PocketPixelsBooth/PrinterNetworkService.swift",
            "PocketPixelsBooth/ThermalImageRasterizer.swift",
            "PocketPixelsBooth/RasterCommandSanitizer.swift",
            "PocketPixelsBooth/CameraService.swift"
        ]
        guard untouchedFiles.allSatisfy({ FileManager.default.fileExists(atPath: $0) && code.range(of: URL(fileURLWithPath: $0).lastPathComponent) == nil }) else {
            throw GalleryUploadError.decoding("Scoped production files self-check failed.")
        }
    }
}

private func debugLog(_ message: String) {
    print("[GalleryUploadDebugSelfChecks] \(message)")
}
#endif
