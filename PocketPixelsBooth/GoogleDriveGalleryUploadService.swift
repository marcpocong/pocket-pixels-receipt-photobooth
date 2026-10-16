//
//  GoogleDriveGalleryUploadService.swift
//  PocketPixelsBooth
//

import Foundation
import UIKit

struct GalleryPendingQueueFailure: Error, LocalizedError {
    let galleryToken: String
    let underlyingError: Error
    var successfulResults: [GalleryUploadResult] = []
    var failedCount: Int = 1

    var errorDescription: String? {
        underlyingError.localizedDescription
    }
}

@MainActor
final class GoogleDriveGalleryUploadService: GalleryUploadService {
    private let configurationProvider: () throws -> GoogleDriveGalleryConfiguration
    private let customerGalleryConfigurationProvider: () throws -> CustomerGalleryConfiguration
    private let urlSession: URLSession
    private let verificationSession: URLSession
    private let connectivityTester: GalleryBackendConnectivityTester
    private let pendingStore: GalleryPendingUploadStore?
    private let onPublicGalleryVerified: @MainActor (String) -> Void
    private static var activeUploadToken: String?
    private static var isQueueProcessing = false
    private(set) static var currentActivity = "Waiting for gallery recovery."

    init(
        configurationProvider: @escaping () throws -> GoogleDriveGalleryConfiguration = { try GoogleDriveGalleryConfiguration.load() },
        customerGalleryConfigurationProvider: @escaping () throws -> CustomerGalleryConfiguration = { try CustomerGalleryConfiguration.load() },
        urlSession: URLSession = GoogleDriveGalleryUploadService.makeUploadSession(),
        connectivityTester: GalleryBackendConnectivityTester = GalleryBackendConnectivityTester(),
        pendingStore: GalleryPendingUploadStore? = nil,
        onPublicGalleryVerified: @escaping @MainActor (String) -> Void = { sessionID in
            EventRunStore.shared.updateSession(id: sessionID) { if $0.galleryVerifiedAt == nil { $0.galleryVerifiedAt = Date() } }
        }
    ) {
        self.onPublicGalleryVerified = onPublicGalleryVerified
        self.configurationProvider = configurationProvider
        self.customerGalleryConfigurationProvider = customerGalleryConfigurationProvider
        self.urlSession = urlSession
        let verificationConfiguration = urlSession.configuration
        verificationConfiguration.waitsForConnectivity = false
        // Cold public pages embed the gallery assets and measured 10–15 seconds at the event.
        // Keep verification bounded without timing out a completed gallery after only 8 seconds.
        verificationConfiguration.timeoutIntervalForRequest = 30
        verificationConfiguration.timeoutIntervalForResource = 45
        self.verificationSession = URLSession(configuration: verificationConfiguration, delegate: GoogleGalleryURLSessionDelegate(), delegateQueue: nil)
        self.connectivityTester = connectivityTester
        self.pendingStore = pendingStore ?? (try? GalleryPendingUploadStore())
    }

    func uploadGallery(
        photos: [UIImage],
        composedReceipt: UIImage,
        sessionID: String,
        createdAt: Date,
        galleryToken: String,
        deviceToken: String
    ) async throws -> GalleryUploadResult {
        let payload = try await prepareAndPersistGallery(
            photos: photos,
            composedReceipt: composedReceipt,
            sessionID: sessionID,
            createdAt: createdAt,
            galleryToken: galleryToken
        )
        return try await uploadPendingPayload(payload, deviceToken: deviceToken)
    }

    func prepareAndPersistGallery(
        photos: [UIImage],
        composedReceipt: UIImage,
        sessionID: String,
        createdAt: Date,
        galleryToken: String,
        frozenGalleryURL: URL? = nil
    ) async throws -> GalleryPreparedUploadPayload {
        // A session's gallery URL is frozen when its token is minted and is already on the QR.
        // Reuse that front door so a config change mid-session or across recovery cannot make the
        // queued payload disagree with the printed QR.
        let customerGalleryBaseURL: URL
        if let frozenGalleryURL {
            guard let frozenBaseURL = GalleryURLBuilder.customerGalleryBaseURL(ofGalleryURL: frozenGalleryURL, galleryToken: galleryToken) else {
                throw GalleryUploadError.invalidGalleryURL
            }
            customerGalleryBaseURL = frozenBaseURL
        } else {
            customerGalleryBaseURL = try customerGalleryConfigurationProvider().baseURL
        }
        let payload = try await Task.detached(priority: .userInitiated) {
            try Self.preparePayload(
                photos: photos,
                composedReceipt: composedReceipt,
                sessionID: sessionID,
                createdAt: createdAt,
                galleryToken: galleryToken,
                customerGalleryBaseURL: customerGalleryBaseURL
            )
        }.value

        guard let pendingStore else {
            throw GalleryUploadError.configuration("Gallery storage is unavailable. Ask the attendant to check iPad storage.")
        }
        try pendingStore.save(payload)
        return payload
    }

    func uploadPendingGallery(galleryToken: String, deviceToken: String) async throws -> GalleryUploadResult {
        guard let pendingStore, let payload = try pendingStore.load(galleryToken: galleryToken) else {
            throw GalleryUploadError.configuration("No pending gallery upload is available for this token.")
        }
        return try await uploadPendingPayload(payload, deviceToken: deviceToken)
    }

    private func uploadPendingPayload(_ payload: GalleryPreparedUploadPayload, deviceToken: String) async throws -> GalleryUploadResult {
        try await beginUpload(galleryToken: payload.galleryToken)
        defer { endUpload(galleryToken: payload.galleryToken) }
        guard let pendingStore else { throw GalleryUploadError.configuration("Gallery storage is unavailable.") }
        guard let payload = try pendingStore.load(galleryToken: payload.galleryToken) else {
            // A preceding owner cleared it only after verifying this exact public URL.
            try await verifyPublicGallery(at: payload.galleryURL)
            recordVerifiedDelivery(sessionID: payload.sessionID)
            return GalleryUploadResult(galleryToken: payload.galleryToken, galleryURL: payload.galleryURL, status: .existingComplete)
        }
        // A previous POST may already have completed. Reconcile the frozen public QR first;
        // otherwise the backend's same-token idempotent POST reconciles incomplete delivery.
        if payload.deliveryState == .deliveryUnknown,
           (try? await verifyPublicGallery(at: payload.galleryURL)) != nil {
            recordVerifiedDelivery(sessionID: payload.sessionID)
            try pendingStore.clear(galleryToken: payload.galleryToken)
            return GalleryUploadResult(galleryToken: payload.galleryToken, galleryURL: payload.galleryURL, status: .existingComplete)
        }
        // Persist ambiguity before any bytes can leave. A process exit during POST must never
        // resurrect an attempted upload as conclusively not started. Storage failure blocks POST.
        try pendingStore.recordAttempt(galleryToken: payload.galleryToken)
        try pendingStore.updateDeliveryState(.deliveryUnknown, galleryToken: payload.galleryToken)
        let configuration = try configurationProvider()
        Self.currentActivity = "Uploading \(payload.sessionID). Waiting for server response (up to 90 seconds)."
        return try await postQueuedPayload(payload, deviceToken: deviceToken, configuration: configuration)
    }

    func retryPendingUpload(deviceToken: String) async throws -> GalleryUploadResult {
        try await retryNextPendingUpload(deviceToken: deviceToken)
    }

    func retryNextPendingUpload(deviceToken: String) async throws -> GalleryUploadResult {
        guard let pendingStore, let payload = try pendingStore.load() else {
            throw GalleryUploadError.configuration("No pending gallery upload is available.")
        }

        return try await uploadPendingPayload(payload, deviceToken: deviceToken)
    }

    func retryPendingQueue(deviceToken: String, maxAttemptsPerGallery: Int = 1) async throws -> [GalleryUploadResult] {
        guard !Self.isQueueProcessing else {
            throw GalleryUploadError.uploadAlreadyActive
        }
        Self.isQueueProcessing = true
        defer { Self.isQueueProcessing = false }

        var results: [GalleryUploadResult] = []
        var failures: [GalleryPendingQueueFailure] = []
        // Reconcile ALL uncertain public galleries before a slow POST can hold up ready ones.
        let snapshot = pendingUploadSummaries()
        for (index, summary) in snapshot.enumerated() where summary.deliveryState == .deliveryUnknown {
            try Task.checkCancellation()
            Self.currentActivity = "Checking public gallery \(index + 1) of \(snapshot.count) · \(summary.sessionID)"
            do {
                if let result = try await reconcilePublicGallery(galleryToken: summary.galleryToken) {
                    results.append(result)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // A damaged item is retained and reported in the upload pass below.
                continue
            }
        }
        // Snapshot once: retained failures must not loop forever or starve later galleries.
        for summary in snapshot {
            try Task.checkCancellation()
            do {
                // Another serialized upload may have completed this item while we waited.
                guard try pendingStore?.load(galleryToken: summary.galleryToken) != nil else { continue }
                let result = try await retryPendingGalleryWithBackoff(
                    galleryToken: summary.galleryToken,
                    deviceToken: deviceToken,
                    maxAttempts: maxAttemptsPerGallery
                )
                results.append(result)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failures.append(GalleryPendingQueueFailure(galleryToken: summary.galleryToken, underlyingError: error))
            }
        }
        Self.currentActivity = "Pass finished: \(results.count) ready; \(pendingUploadSummaries().count) waiting."
        if var failure = failures.first {
            failure.successfulResults = results
            failure.failedCount = failures.count
            throw failure
        }
        return results
    }

    private func reconcilePublicGallery(galleryToken: String) async throws -> GalleryUploadResult? {
        try await beginUpload(galleryToken: galleryToken)
        defer { endUpload(galleryToken: galleryToken) }
        guard let payload = try pendingStore?.load(galleryToken: galleryToken) else { return nil }
        do {
            try await verifyPublicGallery(at: payload.galleryURL)
        } catch {
            try Task.checkCancellation()
            return nil // Public delay/offline is not permission to discard the payload.
        }
        recordVerifiedDelivery(sessionID: payload.sessionID)
        try pendingStore?.clear(galleryToken: galleryToken)
        return GalleryUploadResult(galleryToken: galleryToken, galleryURL: payload.galleryURL, status: .existingComplete)
    }

    func testBackendConnectivity() async -> GalleryBackendConnectivityState {
        await connectivityTester.testBackendReachability()
    }

    func testBackendDiagnostic() async -> GalleryBackendConnectivityState {
        await connectivityTester.testBackendDiagnostic()
    }

    func pendingUploadSummary() -> GalleryPendingUploadSummary? {
        try? pendingStore?.summary()
    }

    func pendingUploadSummaries() -> [GalleryPendingUploadSummary] {
        (try? pendingStore?.summaries()) ?? []
    }

    func hasLegacyPendingUpload() -> Bool {
        pendingStore?.hasLegacyPendingUpload() ?? false
    }

#if DEBUG
    func discardLocalPendingUpload() throws {
        try pendingStore?.discardLocalPendingUpload()
    }
#endif

    func cancel() {
        // Durable uploads own their lock until completion; customer navigation cannot release it.
    }

    nonisolated static func makeRequestBody(
        photos: [UIImage],
        composedReceipt: UIImage,
        sessionID: String,
        createdAt: Date,
        galleryToken: String,
        deviceToken: String
    ) throws -> GalleryUploadRequest {
        let customerGalleryConfiguration = try CustomerGalleryConfiguration.load()
        return try makeRequestBody(
            payload: preparePayload(
                photos: photos,
                composedReceipt: composedReceipt,
                sessionID: sessionID,
                createdAt: createdAt,
                galleryToken: galleryToken,
                customerGalleryBaseURL: customerGalleryConfiguration.baseURL
            ),
            deviceToken: deviceToken
        )
    }

    nonisolated static func preparePayload(
        photos: [UIImage],
        composedReceipt: UIImage,
        sessionID: String,
        createdAt: Date,
        galleryToken: String,
        customerGalleryBaseURL: URL
    ) throws -> GalleryPreparedUploadPayload {
        let preparationStart = Date()
        guard Self.isSupportedPhotoCount(photos.count) else { throw GalleryUploadError.invalidPhotoCount }
        guard sessionID.count <= 32, sessionID.hasPrefix("PP-") else { throw GalleryUploadError.invalidSessionID }

        let createdAtString = makeWireCreatedAtString(from: createdAt)
        guard isValidWireCreatedAtString(createdAtString) else { throw GalleryUploadError.invalidDate }
        let galleryURL = try GalleryURLBuilder.makeGalleryURL(customerGalleryBaseURL: customerGalleryBaseURL, galleryToken: galleryToken)

        let originalDecodedBytes = photos.reduce(0) { partial, image in
            partial + (image.jpegData(compressionQuality: 0.95)?.count ?? 0)
        } + (composedReceipt.jpegData(compressionQuality: 0.95)?.count ?? 0)

        let preparedPhotos = try photos.enumerated().map { index, image in
            GalleryStoredUploadImage(
                filename: String(format: "photo-%02d.jpg", index + 1),
                mimeType: "image/jpeg",
                data: try GalleryUploadPreparation.preparedPhotoData(from: image)
            )
        }

        let preparedReceipt = GalleryStoredUploadImage(
            filename: "receipt-color.jpg",
            mimeType: "image/jpeg",
            data: try GalleryUploadPreparation.preparedReceiptData(from: composedReceipt)
        )

        // `composedReceipt` is the privacy-redacted gallery composition supplied by the
        // session model. The thermal copy must be derived from that image, never from the
        // private physical-print raster.
        let thermalRaster = try ThermalImageRasterizer.rasterize(composedReceipt, purpose: .completeReceipt)
        let preparedThermalReceipt = GalleryStoredUploadImage(
            filename: "receipt-bw.png",
            mimeType: "image/png",
            data: thermalRaster.previewPNGData
        )
        // New galleries contain approved still photos and both receipt representations only.
        // Optional GIF fields remain supported for durable queues and historical manifests.
        let preparedGIF: GalleryStoredUploadImage? = nil

        let imagePreparationDuration = Date().timeIntervalSince(preparationStart)
        let allAssets = preparedPhotos + [preparedReceipt, preparedThermalReceipt] + [preparedGIF].compactMap { $0 }
        let decodedBytes = allAssets.reduce(0) { $0 + $1.data.count }
        let timing = GalleryUploadTimingMetrics(
            imagePreparationDuration: imagePreparationDuration,
            jsonEncodingDuration: 0,
            uploadNetworkDuration: nil,
            totalDuration: nil,
            decodedPayloadByteCount: decodedBytes,
            jsonBodyByteCount: nil
        )
        let metrics = try validateMetrics(for: allAssets, originalDecodedBytes: originalDecodedBytes, timing: timing)
        return GalleryPreparedUploadPayload(
            schemaVersion: 2,
            galleryToken: galleryToken,
            galleryURL: galleryURL,
            sessionID: sessionID,
            createdAt: createdAtString,
            photos: preparedPhotos,
            colorReceipt: preparedReceipt,
            thermalReceipt: preparedThermalReceipt,
            gif: preparedGIF,
            metrics: metrics,
            deliveryState: .notStarted
        )
    }

    nonisolated static func makeRequestBody(payload: GalleryPreparedUploadPayload, deviceToken: String) throws -> GalleryUploadRequest {
        let trimmedToken = deviceToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedToken.count >= 24 else { throw GalleryUploadError.missingDeviceToken }

        return GalleryUploadRequest(
            schemaVersion: payload.schemaVersion,
            deviceToken: trimmedToken,
            galleryToken: payload.galleryToken,
            sessionID: payload.sessionID,
            createdAt: payload.createdAt,
            photos: payload.photos.map {
                GalleryUploadImage(filename: $0.filename, mimeType: $0.mimeType, base64Data: $0.data.base64EncodedString())
            },
            receipt: payload.schemaVersion == 1 ? uploadImage(payload.colorReceipt) : nil,
            colorReceipt: payload.schemaVersion == 2 ? uploadImage(payload.colorReceipt) : nil,
            thermalReceipt: payload.thermalReceipt.map(uploadImage),
            gif: payload.gif.map(uploadImage)
        )
    }

    nonisolated private static func uploadImage(_ image: GalleryStoredUploadImage) -> GalleryUploadImage {
        GalleryUploadImage(filename: image.filename, mimeType: image.mimeType, base64Data: image.data.base64EncodedString())
    }

    static func validateNoDisallowedFields(in request: GalleryUploadRequest) -> Bool {
        guard let data = try? JSONEncoder().encode(request), let json = String(data: data, encoding: .utf8) else { return false }
        let forbidden = ["printer", "port", "deviceIdentifier", "localPath", "driveAccount", "escpos", "raster"]
        return !forbidden.contains { json.localizedCaseInsensitiveContains($0) }
    }

    nonisolated static func validateSuccessfulResponse(
        _ response: GalleryUploadResponse,
        expectedGalleryToken: String? = nil,
        expectedGalleryURL: URL? = nil,
        expectedPhotoCount: Int = BoothFormat.strip.photoCount,
        expectedGIFIncluded: Bool = true
    ) -> Bool {
        guard response.ok,
              Self.isSupportedPhotoCount(expectedPhotoCount),
              response.fileCount == expectedPhotoCount + (response.schemaVersion == 2 ? (expectedGIFIncluded ? 4 : 3) : 2),
              let galleryToken = response.galleryToken,
              let galleryURL = response.galleryURL,
              Self.isConfirmedCompletionStatus(response.status),
              GalleryTokenGenerator.isValidGalleryToken(galleryToken),
              galleryURL.scheme?.lowercased() == "https",
              galleryURL.host() != nil else { return false }
        if let expectedGalleryToken, galleryToken != expectedGalleryToken { return false }
        // The backend builds its URL from its own configured front door, which may legitimately
        // differ from the frozen URL during the Made to Keep migration (legacy queued payloads,
        // or app and Apps Script configured at different times). Same token is what matters.
        if let expectedGalleryURL,
           !GalleryURLBuilder.identifiesSameGallery(galleryURL, expectedGalleryURL, galleryToken: galleryToken) {
            return false
        }
        return true
    }

#if DEBUG
    static func runDebugSelfCheck() throws {
        let responseJSON = """
        {"ok":true,"schemaVersion":1,"galleryToken":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","galleryURL":"https://pocket-pixels-gallery.pocketpixels-ceb.workers.dev/?g=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","fileCount":5,"status":"existingComplete"}
        """
        let response = try JSONDecoder().decode(GalleryUploadResponse.self, from: Data(responseJSON.utf8))
        guard validateSuccessfulResponse(response) else { throw GalleryUploadError.decoding("Self-check response validation failed.") }
    }
#endif

    private func postQueuedPayload(
        _ payload: GalleryPreparedUploadPayload,
        deviceToken: String,
        configuration: GoogleDriveGalleryConfiguration
    ) async throws -> GalleryUploadResult {
        do {
            let result = try await post(payload: payload, deviceToken: deviceToken, configuration: configuration)
            // The upload response proves backend acceptance; only a completed public page proves
            // delivery through the exact front door printed on this guest's receipt. This bounded
            // read runs in the gallery task and never gates physical receipt printing.
            Self.currentActivity = "Verifying public delivery · \(payload.sessionID)"
            try await verifyPublicGallery(at: payload.galleryURL)
            recordVerifiedDelivery(sessionID: payload.sessionID)
            try pendingStore?.clear(galleryToken: payload.galleryToken)
            return result
        } catch GalleryUploadError.deliveryUnknown {
            try pendingStore?.updateDeliveryState(.deliveryUnknown, galleryToken: payload.galleryToken, lastSafeError: GalleryUploadError.deliveryUnknown.localizedDescription)
            throw GalleryUploadError.deliveryUnknown
        } catch GalleryUploadError.network(let message) {
            try pendingStore?.updateDeliveryState(.deliveryUnknown, galleryToken: payload.galleryToken, lastSafeError: message)
            throw GalleryUploadError.pendingNoInternet
        } catch GalleryUploadError.timeout {
            try pendingStore?.updateDeliveryState(.deliveryUnknown, galleryToken: payload.galleryToken, lastSafeError: GalleryUploadError.timeout.localizedDescription)
            throw GalleryUploadError.deliveryUnknown
        } catch {
            try? pendingStore?.updateDeliveryState(.deliveryUnknown, galleryToken: payload.galleryToken, lastSafeError: error.localizedDescription)
            throw error
        }
    }

    private func recordVerifiedDelivery(sessionID: String) {
        onPublicGalleryVerified(sessionID)
    }

    private func verifyPublicGallery(at url: URL) async throws {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await verificationSession.data(for: request)
            guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                  let html = String(data: data, encoding: .utf8),
                  html.contains("data-pocket-pixels-gallery-status=\"complete\"") else {
                throw GalleryUploadError.deliveryUnknown
            }
        } catch {
            throw GalleryUploadError.deliveryUnknown
        }
    }

    private func post(
        payload: GalleryPreparedUploadPayload,
        deviceToken: String,
        configuration: GoogleDriveGalleryConfiguration
    ) async throws -> GalleryUploadResult {
        let totalStart = Date()
        let requestBody = try Self.makeRequestBody(payload: payload, deviceToken: deviceToken)
        let jsonStart = Date()
        let encodedBody = try JSONEncoder().encode(requestBody)
        let jsonDuration = Date().timeIntervalSince(jsonStart)
#if DEBUG
        debugLog(Self.makeSanitizedRequestDiagnostics(requestBody, encodedBody: encodedBody).description)
        debugLog("Upload timing before POST. imagePreparation=\(String(format: "%.3f", payload.metrics.timing?.imagePreparationDuration ?? 0))s jsonEncoding=\(String(format: "%.3f", jsonDuration))s decodedBytes=\(payload.metrics.totalDecodedBytes) jsonBytes=\(encodedBody.count)")
#endif

        var request = URLRequest(url: configuration.webAppURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = encodedBody

        let networkStart = Date()
        let responseData: Data
        let response: URLResponse
        do {
            (responseData, response) = try await urlSession.data(for: request)
        } catch is CancellationError {
            throw GalleryUploadError.deliveryUnknown
        } catch let error as URLError where error.code == .cancelled {
            throw GalleryUploadError.deliveryUnknown
        } catch let error as URLError where error.code == .timedOut {
            debugLog("POST timed out after transmission began. Host: \(error.failureURLString.flatMap { URL(string: $0)?.host() } ?? configuration.webAppURL.host() ?? "unknown"), URLError code: \(error.errorCode).")
            throw GalleryUploadError.deliveryUnknown
        } catch let error as URLError {
            let state = GalleryNetworkClassifier.classify(urlError: error, fallbackHost: configuration.webAppURL.host())
            debugLog(state.diagnosticDescription)
            switch error.code {
            case .notConnectedToInternet, .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost:
                throw GalleryUploadError.network(state.diagnosticDescription)
            default:
                throw GalleryUploadError.deliveryUnknown
            }
        } catch {
            throw GalleryUploadError.deliveryUnknown
        }
        let networkDuration = Date().timeIntervalSince(networkStart)

        guard let httpResponse = response as? HTTPURLResponse else { throw GalleryUploadError.deliveryUnknown }
        guard (200...299).contains(httpResponse.statusCode) else {
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 { throw GalleryUploadError.unauthorized }
            if let serverResponse = try? JSONDecoder().decode(GalleryUploadResponse.self, from: responseData), let error = serverResponse.error {
                if Self.isAuthenticationFailure(serverResponse) {
                    throw GalleryUploadError.unauthorized
                }
                if Self.isTemporaryServerResponse(serverResponse, httpStatus: httpResponse.statusCode) {
                    throw GalleryUploadError.network(Self.safeServerMessage(response: serverResponse, fallback: "Upload service is temporarily unavailable."))
                }
                if serverResponse.status == "conflict" || serverResponse.status == "manualInspectionRequired" {
                    throw GalleryUploadError.conflictManualInspection(Self.safeServerMessage(response: serverResponse, fallback: error))
                }
                throw GalleryUploadError.server(Self.safeServerMessage(response: serverResponse, fallback: error))
            }
            if httpResponse.statusCode == 408 || httpResponse.statusCode >= 500 {
                throw GalleryUploadError.deliveryUnknown
            }
            if httpResponse.statusCode == 429 {
                throw GalleryUploadError.network("Upload service is busy. Please retry later.")
            }
            throw GalleryUploadError.httpStatus(httpResponse.statusCode)
        }

        let uploadResponse: GalleryUploadResponse
        do {
            uploadResponse = try JSONDecoder().decode(GalleryUploadResponse.self, from: responseData)
        } catch {
            throw GalleryUploadError.deliveryUnknown
        }

        guard uploadResponse.ok else {
            if Self.isAuthenticationFailure(uploadResponse) {
                throw GalleryUploadError.unauthorized
            }
            if Self.isTemporaryServerResponse(uploadResponse) {
                throw GalleryUploadError.network(Self.safeServerMessage(response: uploadResponse, fallback: "Upload service is temporarily unavailable."))
            }
            if uploadResponse.status == "conflict" || uploadResponse.status == "manualInspectionRequired" {
                throw GalleryUploadError.conflictManualInspection(Self.safeServerMessage(response: uploadResponse, fallback: "Gallery requires manual inspection."))
            }
            throw GalleryUploadError.server(Self.safeServerMessage(response: uploadResponse, fallback: "Gallery upload failed."))
        }

        guard Self.validateSuccessfulResponse(uploadResponse, expectedGalleryToken: payload.galleryToken, expectedGalleryURL: payload.galleryURL, expectedPhotoCount: payload.photos.count, expectedGIFIncluded: payload.gif != nil),
              let galleryToken = uploadResponse.galleryToken,
              let galleryURL = uploadResponse.galleryURL else {
            throw GalleryUploadError.deliveryUnknown
        }

#if DEBUG
        let totalDuration = Date().timeIntervalSince(totalStart)
        debugLog("Gallery upload succeeded. Gallery token: \(GalleryTokenGenerator.redacted(galleryToken)). URL host: \(galleryURL.host() ?? "unknown"). uploadNetwork=\(String(format: "%.3f", networkDuration))s total=\(String(format: "%.3f", totalDuration))s responseBytes=\(responseData.count)")
#endif
        // Always report the frozen URL (the one on the printed QR), never the backend's rebuilt one.
        return GalleryUploadResult(galleryToken: galleryToken, galleryURL: payload.galleryURL, status: GalleryUploadResultStatus(serverStatus: uploadResponse.status))
    }

    private func beginUpload(galleryToken: String) async throws {
        // MainActor makes acquisition atomic across foreground and recovery service instances.
        while Self.activeUploadToken != nil {
            try await Task.sleep(for: .milliseconds(100))
        }
        try Task.checkCancellation()
        Self.activeUploadToken = galleryToken
    }

    private func endUpload(galleryToken: String) {
        guard Self.activeUploadToken == galleryToken else {
            return
        }
        Self.activeUploadToken = nil
    }

    private func retryPendingGalleryWithBackoff(
        galleryToken: String,
        deviceToken: String,
        maxAttempts: Int
    ) async throws -> GalleryUploadResult {
        let delays: [Duration] = [.seconds(2), .seconds(5), .seconds(10)]
        var lastError: Error?
        for attempt in 1...max(1, maxAttempts) {
            do {
                return try await uploadPendingGallery(galleryToken: galleryToken, deviceToken: deviceToken)
            } catch {
                guard Self.isTemporaryRetryable(error) else {
                    throw error
                }
                lastError = error
                if attempt < maxAttempts {
                    let delay = delays[min(attempt - 1, delays.count - 1)]
                    try await Task.sleep(for: delay)
                }
            }
        }
        throw lastError ?? GalleryUploadError.pendingNoInternet
    }

    nonisolated private static func makeUploadSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 90
        configuration.timeoutIntervalForResource = 180
        return URLSession(configuration: configuration, delegate: GoogleGalleryURLSessionDelegate(), delegateQueue: nil)
    }

    nonisolated private static func validateMetrics(
        for images: [GalleryStoredUploadImage],
        originalDecodedBytes: Int? = nil,
        timing: GalleryUploadTimingMetrics? = nil
    ) throws -> GalleryPreparedUploadMetrics {
        let fileMetrics = images.map { GalleryPreparedUploadFileMetric(filename: $0.filename, decodedBytes: $0.data.count) }
        let totalDecodedBytes = fileMetrics.reduce(0) { $0 + $1.decodedBytes }
        let estimatedBase64Bytes = GalleryPreparedUploadBudget.estimatedBase64JSONBytes(for: images)
        try GalleryPreparedUploadBudget.validate(images: images, requiresGIF: images.contains { $0.filename == "session.gif" })

        return GalleryPreparedUploadMetrics(
            files: fileMetrics,
            totalDecodedBytes: totalDecodedBytes,
            estimatedBase64JSONBytes: estimatedBase64Bytes,
            originalDecodedBytes: originalDecodedBytes,
            timing: timing
        )
    }

    nonisolated private static func makeWireCreatedAtString(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    nonisolated private static func isValidWireCreatedAtString(_ value: String) -> Bool {
        guard !value.isEmpty,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.contains(".") else {
            return false
        }
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime]
        guard let parsedDate = formatter.date(from: value) else {
            return false
        }
        return formatter.string(from: parsedDate) == value
    }

#if DEBUG
    static func makeSanitizedRequestDiagnostics(_ request: GalleryUploadRequest, encodedBody: Data) -> GalleryRequestDiagnostics {
        guard let receipt = request.colorReceipt ?? request.receipt else {
            preconditionFailure("Validated gallery request has no receipt")
        }
        return GalleryRequestDiagnostics(
            schemaVersion: request.schemaVersion,
            hasDeviceToken: !request.deviceToken.isEmpty,
            galleryTokenCharacterCount: request.galleryToken.count,
            galleryTokenMatchesLowercaseHex: GalleryTokenGenerator.isValidGalleryToken(request.galleryToken),
            sessionID: request.sessionID,
            createdAt: request.createdAt,
            photoCount: request.photos.count,
            photoFilenames: request.photos.map(\.filename),
            photoMimeTypes: request.photos.map(\.mimeType),
            photoBase64CharacterCounts: request.photos.map { $0.base64Data.count },
            receiptFilename: receipt.filename,
            receiptMimeType: receipt.mimeType,
            receiptBase64CharacterCount: receipt.base64Data.count,
            jsonBodyByteCount: encodedBody.count
        )
    }
#endif

    private static func safeServerMessage(response: GalleryUploadResponse, fallback: String) -> String {
        let message = response.error?.isEmpty == false ? response.error ?? fallback : fallback
        var parts: [String] = []
        if let code = response.errorCode, !code.isEmpty { parts.append("\(code): \(message)") } else { parts.append(message) }
        if let field = response.field, !field.isEmpty { parts.append("Field: \(field)") }
        if let stage = response.stage, !stage.isEmpty { parts.append("Stage: \(stage)") }
        if let detail = response.detail, !detail.isEmpty { parts.append("Detail: \(detail)") }
        return parts.joined(separator: " | ")
    }

    private static func isTemporaryServerResponse(_ response: GalleryUploadResponse, httpStatus: Int? = nil) -> Bool {
        if response.errorCode == "UPLOAD_SERVICE_BUSY" {
            return true
        }
        if let httpStatus, httpStatus == 408 || httpStatus == 429 || httpStatus >= 500 {
            return true
        }
        return false
    }

    nonisolated static func isAuthenticationFailure(_ response: GalleryUploadResponse) -> Bool {
        switch response.errorCode {
        case "MISSING_DEVICE_TOKEN", "INVALID_DEVICE_TOKEN", "SERVER_NOT_CONFIGURED":
            true
        default:
            false
        }
    }

    nonisolated private static func isConfirmedCompletionStatus(_ status: String?) -> Bool {
        status == "created" ||
        status == "existingComplete" ||
        status == "completedIncomplete"
    }

    nonisolated static func isSupportedPhotoCount(_ count: Int) -> Bool {
        BoothConfiguration.minimumPhotosPerSession...BoothConfiguration.maximumPhotosPerSession ~= count
    }

    private static func isTemporaryRetryable(_ error: Error) -> Bool {
        guard let uploadError = error as? GalleryUploadError else {
            return false
        }
        switch uploadError {
        case .pendingNoInternet, .network, .timeout, .deliveryUnknown:
            return true
        default:
            return false
        }
    }
}

nonisolated private func debugLog(_ message: String) {
#if DEBUG
    print("[GoogleDriveGalleryUploadService] \(message)")
#endif
}
