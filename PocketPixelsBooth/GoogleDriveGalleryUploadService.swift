//
//  GoogleDriveGalleryUploadService.swift
//  PocketPixelsBooth
//

import Foundation
import OSLog
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
    private static let performanceLogger = Logger(subsystem: "com.pocketpixels.PocketPixelsBooth", category: "GalleryPerformance")
    private let configurationProvider: () throws -> GoogleDriveGalleryConfiguration
    private let customerGalleryConfigurationProvider: () throws -> CustomerGalleryConfiguration
    private let urlSession: URLSession
    private let verificationSession: URLSession
    private let connectivityTester: GalleryBackendConnectivityTester
    private let pendingStore: GalleryPendingUploadStore?
    private let verificationStore: GalleryVerificationStore?
    private let onPublicGalleryVerified: @MainActor (String) -> Void
    var onStageChange: (@MainActor (String, GalleryUploadPhase) -> Void)?
    private let scheduler: GalleryUploadScheduler
    private static var isQueueProcessing = false
    private(set) static var currentActivity = "Waiting for gallery recovery."

    init(
        configurationProvider: @escaping () throws -> GoogleDriveGalleryConfiguration = { try GoogleDriveGalleryConfiguration.load() },
        customerGalleryConfigurationProvider: @escaping () throws -> CustomerGalleryConfiguration = { try CustomerGalleryConfiguration.load() },
        urlSession: URLSession = GoogleDriveGalleryUploadService.makeUploadSession(),
        connectivityTester: GalleryBackendConnectivityTester = GalleryBackendConnectivityTester(),
        pendingStore: GalleryPendingUploadStore? = nil,
        verificationStore: GalleryVerificationStore? = nil,
        scheduler: GalleryUploadScheduler? = nil,
        onPublicGalleryVerified: @escaping @MainActor (String) -> Void = { sessionID in
            EventRunStore.shared.updateSession(id: sessionID) { if $0.galleryVerifiedAt == nil { $0.galleryVerifiedAt = Date() } }
        }
    ) {
        self.scheduler = scheduler ?? .shared
        self.verificationStore = verificationStore ?? (try? GalleryVerificationStore())
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
        return try await uploadPendingGallery(galleryToken: payload.galleryToken, deviceToken: deviceToken)
    }

    func prepareAndPersistGallery(
        photos: [UIImage],
        composedReceipt: UIImage,
        sessionID: String,
        createdAt: Date,
        galleryToken: String,
        frozenGalleryURL: URL? = nil,
        shareFriendlyReceipt: UIImage? = nil, receiptVariants: GalleryReceiptVariants? = nil
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
        onStageChange?(galleryToken, .preparing)
        let payload = try await Task.detached(priority: .userInitiated) {
            try Self.preparePayload(
                photos: photos,
                composedReceipt: composedReceipt,
                sessionID: sessionID,
                createdAt: createdAt,
                galleryToken: galleryToken,
                customerGalleryBaseURL: customerGalleryBaseURL,
                shareFriendlyReceipt: shareFriendlyReceipt, receiptVariants: receiptVariants
            )
        }.value

        try await withPendingStore(.durablePersistence) { try $0.save(payload) }
        NotificationCenter.default.post(name: .galleryQueueChanged, object: nil)
        return payload
    }

    func uploadPendingGallery(galleryToken: String, deviceToken: String, priority: GalleryUploadScheduler.Priority = .guest, alreadyReconciled: Bool = false) async throws -> GalleryUploadResult {
        let started = ProcessInfo.processInfo.systemUptime
        var succeeded = false
        defer { GalleryPerformance.record(.totalDelivery, since: started, succeeded: succeeded) }
        let result = try await scheduler.perform(token: galleryToken, priority: priority) { [self] in
            do {
                guard let delivery = try await withPendingStore(.diskLoad, { try $0.delivery(galleryToken: galleryToken) }) else {
                    throw GalleryUploadError.configuration("No pending gallery upload is available for this token.")
                }
                try await withPendingStore(.metadataWrite) { try $0.recordAttempt(galleryToken: galleryToken) }
                if delivery.state == .posted {
                    // Metadata alone is sufficient. Accepted uploads must never POST again.
                    await scheduler.beginVerification(token: galleryToken)
                    try await verifyPublicGallery(delivery.target)
                    try await finishDelivery(delivery.target)
                    return GalleryUploadResult(galleryToken: galleryToken, galleryURL: delivery.target.url, status: .existingComplete)
                }
                if delivery.state == .deliveryUnknown, !alreadyReconciled {
                    var publiclyComplete = false
                    do {
                        // Retain the lane: a failed public read may need same-token idempotent repair.
                        try await verifyPublicGallery(delivery.target)
                        publiclyComplete = true
                    } catch {
                        if error is URLError { throw error }
                        if case GalleryPublicVerificationError.rateLimited = error { throw error }
                        if case GalleryUploadError.configuration = error { throw error }
                        try Task.checkCancellation()
                    }
                    if publiclyComplete {
                        // Local commit errors must never fall through into another transmission.
                        try await withPendingStore(.metadataWrite) { try $0.updateDeliveryState(.posted, galleryToken: galleryToken) }
                        await scheduler.beginVerification(token: galleryToken)
                        try await finishDelivery(delivery.target)
                        return GalleryUploadResult(galleryToken: galleryToken, galleryURL: delivery.target.url, status: .existingComplete)
                    }
                }
                // Read media exactly once, after acquiring this token. No queued copies of full galleries.
                guard let payload = try await withPendingStore(.diskLoad, { try $0.load(galleryToken: galleryToken) }) else {
                    throw GalleryUploadError.configuration("Pending gallery files are unavailable.")
                }
                let configuration = try configurationProvider()
                try await withPendingStore(.metadataWrite) { try $0.updateDeliveryState(.deliveryUnknown, galleryToken: galleryToken) }
                scheduler.report("Uploading gallery. Waiting for backend acknowledgement.", phase: .uploading)
                return try await postQueuedPayload(payload, deviceToken: deviceToken, configuration: configuration)
            } catch {
                // Failure to save retry metadata cannot release the token before the operation ends.
                try await withPendingStore(.metadataWrite) { try $0.recordFailure(galleryToken: galleryToken, error: error) }
                throw error
            }
        }
        succeeded = true
        return result
    }

    private func withPendingStore<T: Sendable>(_ stage: GalleryPerformance.Stage,
        _ work: @escaping @Sendable (GalleryPendingUploadStore) throws -> T) async throws -> T {
        guard let pendingStore else { throw GalleryUploadError.configuration("Gallery storage is unavailable.") }
        do {
            return try await GalleryDiskIO.shared.run { try GalleryPerformance.measure(stage) { try work(pendingStore) } }
        } catch let error as GalleryUploadError { throw error }
        catch { throw GalleryUploadError.configuration("Gallery storage could not be read or updated. Files are retained; check iPad storage before retrying.") }
    }

    private func finishDelivery(_ target: GalleryVerificationTarget) async throws {
        try await recordVerifiedDelivery(target, source: "upload-public-readiness")
        try await withPendingStore(.metadataWrite) { try $0.clear(galleryToken: target.token) }
        onStageChange?(target.token, .success(target.url))
    }

    func retryPendingUpload(deviceToken: String) async throws -> GalleryUploadResult {
        try await retryNextPendingUpload(deviceToken: deviceToken)
    }

    func retryNextPendingUpload(deviceToken: String) async throws -> GalleryUploadResult {
        guard let summary = try await withPendingStore(.diskLoad, { try $0.summary() }) else {
            throw GalleryUploadError.configuration("No pending gallery upload is available.")
        }
        return try await uploadPendingGallery(galleryToken: summary.galleryToken, deviceToken: deviceToken)
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
        let snapshot = pendingUploadSummaries().filter { !$0.needsAttention && ($0.nextAttemptAt == nil || $0.nextAttemptAt! <= Date()) }
        var reconciled = Set<String>()
        var deferred = Set<String>()
        for (index, summary) in snapshot.enumerated() where summary.deliveryState == .deliveryUnknown {
            try Task.checkCancellation()
            Self.currentActivity = "Checking public gallery \(index + 1) of \(snapshot.count) · \(summary.sessionID)"
            do {
                reconciled.insert(summary.galleryToken)
                if let result = try await reconcilePublicGallery(galleryToken: summary.galleryToken) {
                    results.append(result)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try await withPendingStore(.metadataWrite) { try $0.recordFailure(galleryToken: summary.galleryToken, error: error) }
                deferred.insert(summary.galleryToken)
                failures.append(GalleryPendingQueueFailure(galleryToken: summary.galleryToken, underlyingError: error))
                continue
            }
        }
        // Snapshot once: retained failures must not loop forever or starve later galleries.
        for summary in snapshot where !deferred.contains(summary.galleryToken) {
            try Task.checkCancellation()
            do {
                // Another serialized upload may have completed this item while we waited.
                guard try await withPendingStore(.diskLoad, { try $0.delivery(galleryToken: summary.galleryToken) }) != nil else { continue }
                let result = try await retryPendingGalleryWithBackoff(
                    galleryToken: summary.galleryToken,
                    deviceToken: deviceToken,
                    maxAttempts: maxAttemptsPerGallery, alreadyReconciled: reconciled.contains(summary.galleryToken)
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
        do {
            return try await scheduler.perform(token: galleryToken, priority: .recovery) { [self] in
                guard let delivery = try await withPendingStore(.diskLoad, { try $0.delivery(galleryToken: galleryToken) }) else {
                    throw GalleryUploadError.configuration("No pending gallery is available for reconciliation.")
                }
                try await withPendingStore(.metadataWrite) { try $0.recordAttempt(galleryToken: galleryToken) }
                await scheduler.beginVerification(token: galleryToken)
                try await verifyPublicGallery(delivery.target)
                try await withPendingStore(.metadataWrite) { try $0.updateDeliveryState(.posted, galleryToken: galleryToken) }
                try await finishDelivery(delivery.target)
                return GalleryUploadResult(galleryToken: galleryToken, galleryURL: delivery.target.url, status: .existingComplete)
            }
        } catch {
            try Task.checkCancellation()
            if error is URLError { throw error }
            if case GalleryPublicVerificationError.rateLimited = error { throw error }
            if case GalleryUploadError.configuration = error { throw error }
            return nil
        }
    }

    /// Explicit historical repair shares the same token lease and never transmits media.
    func verifyOriginalGallery(_ target: GalleryVerificationTarget) async throws {
        _ = try await scheduler.perform(token: target.token, priority: .recovery) { [self] in
            let pending = try await withPendingStore(.diskLoad) { try $0.delivery(galleryToken: target.token) }
            if let pending {
                guard pending.target.sessionID == target.sessionID, pending.target.url == target.url else { throw GalleryUploadError.deliveryUnknown }
            }
            let exact = pending?.target ?? target
            await scheduler.beginVerification(token: target.token)
            onStageChange?(target.token, .verifying)
            let source = try await GalleryPublicVerifier.verify(exact, session: verificationSession)
            if let pending, pending.state != .posted {
                try await withPendingStore(.metadataWrite) { try $0.updateDeliveryState(.posted, galleryToken: target.token) }
            }
            try await recordVerifiedDelivery(exact, source: source)
            if pending != nil { try await withPendingStore(.metadataWrite) { try $0.clear(galleryToken: target.token) } }
            onStageChange?(target.token, .success(exact.url))
            return GalleryUploadResult(galleryToken: target.token, galleryURL: target.url, status: .existingComplete)
        }
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
        customerGalleryBaseURL: URL,
        shareFriendlyReceipt: UIImage? = nil, receiptVariants: GalleryReceiptVariants? = nil
    ) throws -> GalleryPreparedUploadPayload {
        let preparationStart = Date()
        let performanceStart = ProcessInfo.processInfo.systemUptime
        var prepared = false
        defer { GalleryPerformance.record(.imagePreparation, since: performanceStart, succeeded: prepared) }
        guard Self.isSupportedPhotoCount(photos.count) else { throw GalleryUploadError.invalidPhotoCount }
        guard sessionID.count <= 64, sessionID.hasPrefix("PP-") else { throw GalleryUploadError.invalidSessionID }

        let createdAtString = makeWireCreatedAtString(from: createdAt)
        guard isValidWireCreatedAtString(createdAtString) else { throw GalleryUploadError.invalidDate }
        let galleryURL = try GalleryURLBuilder.makeGalleryURL(customerGalleryBaseURL: customerGalleryBaseURL, galleryToken: galleryToken)

        // Avoid re-encoding full-resolution originals just to estimate a diagnostic size.
        let originalDecodedBytes: Int? = nil

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
        // session model. The black & white copy must be derived from that image, never from the
        // private physical print. The legacy `thermalReceipt` / `receipt-bw.png` slot now carries a
        // smooth 8-bit grayscale customer preview, not the 1-bit printer raster.
        let preparedThermalReceipt: GalleryStoredUploadImage? = receiptVariants == nil ? GalleryStoredUploadImage(
            filename: "receipt-bw.png",
            mimeType: "image/png",
            data: try GalleryUploadPreparation.preparedMonochromeReceiptData(from: composedReceipt)
        ) : nil
        // Schema 4 derives both B&W variants in the browser from privacy-safe color assets.
        // Optional GIF fields remain supported for durable queues and historical manifests.
        let preparedGIF: GalleryStoredUploadImage? = nil

        guard (receiptVariants?.hasAlternative ?? false) == (shareFriendlyReceipt != nil) else {
            throw GalleryUploadError.missingReceipt
        }
        let preparedShareReceipt = try shareFriendlyReceipt.map {
            GalleryStoredUploadImage(filename: "receipt-share-color.jpg", mimeType: "image/jpeg",
                data: try GalleryUploadPreparation.preparedReceiptData(from: $0))
        }
        let imagePreparationDuration = Date().timeIntervalSince(preparationStart)
        let allAssets = preparedPhotos + [preparedReceipt] + [preparedThermalReceipt, preparedGIF, preparedShareReceipt].compactMap { $0 }
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
        prepared = true
        return GalleryPreparedUploadPayload(
            schemaVersion: receiptVariants == nil ? 2 : 4,
            galleryToken: galleryToken,
            galleryURL: galleryURL,
            sessionID: sessionID,
            createdAt: createdAtString,
            photos: preparedPhotos,
            colorReceipt: preparedReceipt,
            thermalReceipt: preparedThermalReceipt,
            gif: preparedGIF,
            metrics: metrics,
            deliveryState: .notStarted,
            shareColorReceipt: preparedShareReceipt, receiptVariants: receiptVariants
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
            colorReceipt: payload.schemaVersion >= 2 ? uploadImage(payload.colorReceipt) : nil,
            thermalReceipt: payload.thermalReceipt.map(uploadImage),
            gif: payload.gif.map(uploadImage),
            shareColorReceipt: payload.shareColorReceipt.map(uploadImage), receiptVariants: payload.receiptVariants
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
        expectedGIFIncluded: Bool = true, expectedShareReceiptIncluded: Bool = false
    ) -> Bool {
        guard response.ok,
              Self.isSupportedPhotoCount(expectedPhotoCount),
              response.fileCount == expectedPhotoCount + ((response.schemaVersion ?? 1) >= 2 ? ((response.schemaVersion == 4 ? 2 : 3) + (expectedGIFIncluded ? 1 : 0) + (expectedShareReceiptIncluded ? 1 : 0)) : 2),
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
            try await withPendingStore(.metadataWrite) { try $0.updateDeliveryState(.posted, galleryToken: payload.galleryToken) }
            await scheduler.beginVerification(token: payload.galleryToken)
            // The upload response proves backend acceptance; only a completed public page proves
            // delivery through the exact front door printed on this guest's receipt. This bounded
            // read runs in the gallery task and never gates physical receipt printing.
            scheduler.report("Verifying public delivery through the printed QR address.", phase: .verifying)
            Self.currentActivity = "Verifying public delivery · \(payload.sessionID)"
            try await verifyPublicGallery(GalleryVerificationTarget(payload))
            try await finishDelivery(GalleryVerificationTarget(payload))
            return result
        } catch GalleryUploadError.deliveryUnknown {
            try await retainDeliveryState(payload, lastSafeError: GalleryUploadError.deliveryUnknown.localizedDescription)
            throw GalleryUploadError.deliveryUnknown
        } catch GalleryUploadError.network(let message) {
            try await retainDeliveryState(payload, lastSafeError: message)
            throw GalleryUploadError.network("Gallery backend is unreachable. Photos are retained.")
        } catch GalleryUploadError.timeout {
            try await retainDeliveryState(payload, lastSafeError: GalleryUploadError.timeout.localizedDescription)
            throw GalleryUploadError.timeout
        } catch {
            try? await retainDeliveryState(payload, lastSafeError: error.localizedDescription)
            throw error
        }
    }

    private func retainDeliveryState(_ payload: GalleryPreparedUploadPayload, lastSafeError: String) async throws {
        try await withPendingStore(.metadataWrite) { store in
            let state = try store.delivery(galleryToken: payload.galleryToken)?.state
            try store.updateDeliveryState(state == .posted ? .posted : .deliveryUnknown,
                galleryToken: payload.galleryToken, lastSafeError: lastSafeError)
        }
    }

    private func recordVerifiedDelivery(_ target: GalleryVerificationTarget, source: String) async throws {
        guard let verificationStore else { throw GalleryUploadError.configuration("Gallery verification storage is unavailable. The pending gallery is retained; retry verification after checking storage.") }
        do {
            try await GalleryDiskIO.shared.run {
                try GalleryPerformance.measure(.metadataWrite) {
                    try verificationStore.record(sessionID: target.sessionID, token: target.token, url: target.url, source: source)
                }
            }
        } catch {
            throw GalleryUploadError.configuration("Gallery is online, but its local verification could not be saved. The pending gallery is retained. Check storage and retry verification.")
        }
        onPublicGalleryVerified(target.sessionID)
    }

    private func verifyPublicGallery(_ target: GalleryVerificationTarget) async throws {
        scheduler.report("Verifying public delivery through the printed QR address.", phase: .verifying)
        onStageChange?(target.token, .verifying)
        let start = ProcessInfo.processInfo.systemUptime
        var succeeded = false
        defer { GalleryPerformance.record(.publicVerification, since: start, succeeded: succeeded) }
        _ = try await GalleryPublicVerifier.verify(target, session: verificationSession)
        succeeded = true
    }

    private func post(
        payload: GalleryPreparedUploadPayload,
        deviceToken: String,
        configuration: GoogleDriveGalleryConfiguration
    ) async throws -> GalleryUploadResult {
        let totalStart = Date()
        let jsonStart = Date()
        let (_, encodedBody) = try await Task.detached(priority: .userInitiated) {
            let body = try GalleryPerformance.measure(.base64Encoding) { try Self.makeRequestBody(payload: payload, deviceToken: deviceToken) }
            return (body, try GalleryPerformance.measure(.jsonEncoding) { try JSONEncoder().encode(body) })
        }.value
        let jsonDuration = Date().timeIntervalSince(jsonStart)
#if DEBUG
        debugLog("Upload timing before POST. imagePreparation=\(String(format: "%.3f", payload.metrics.timing?.imagePreparationDuration ?? 0))s jsonEncoding=\(String(format: "%.3f", jsonDuration))s decodedBytes=\(payload.metrics.totalDecodedBytes) jsonBytes=\(encodedBody.count)")
#endif

        var request = URLRequest(url: configuration.webAppURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = encodedBody

        onStageChange?(payload.galleryToken, .uploading)
        let networkStart = Date()
        let performanceNetworkStart = ProcessInfo.processInfo.systemUptime
        var networkSucceeded = false
        let responseData: Data
        let response: URLResponse
        do {
            defer { GalleryPerformance.record(.networkPOST, since: performanceNetworkStart, bytes: encodedBody.count, succeeded: networkSucceeded) }
            (responseData, response) = try await urlSession.data(for: request)
            networkSucceeded = true
        } catch is CancellationError {
            throw GalleryUploadError.deliveryUnknown
        } catch let error as URLError where error.code == .cancelled {
            throw GalleryUploadError.deliveryUnknown
        } catch let error as URLError where error.code == .timedOut {
            debugLog("POST timed out after transmission began. Host: \(error.failureURLString.flatMap { URL(string: $0)?.host() } ?? configuration.webAppURL.host() ?? "unknown"), URLError code: \(error.errorCode).")
            throw GalleryUploadError.timeout
        } catch let error as URLError {
            let state = GalleryNetworkClassifier.classify(urlError: error, fallbackHost: configuration.webAppURL.host())
            debugLog(state.diagnosticDescription)
            switch error.code {
            case .notConnectedToInternet:
                throw GalleryUploadError.pendingNoInternet
            case .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost:
                throw GalleryUploadError.network(state.diagnosticDescription)
            default:
                throw GalleryUploadError.deliveryUnknown
            }
        } catch {
            throw GalleryUploadError.deliveryUnknown
        }
        let networkDuration = Date().timeIntervalSince(networkStart)
        onStageChange?(payload.galleryToken, .processing)
        let validationStart = ProcessInfo.processInfo.systemUptime
        var validationSucceeded = false
        defer { GalleryPerformance.record(.responseValidation, since: validationStart, bytes: responseData.count, succeeded: validationSucceeded) }
        Self.performanceLogger.info("Gallery POST: elapsedMs=\(Int(networkDuration*1000)) imagePreparationMs=\(Int((payload.metrics.timing?.imagePreparationDuration ?? 0)*1000)) jsonEncodingMs=\(Int(jsonDuration*1000)) requestBytes=\(encodedBody.count)")

        guard let httpResponse = response as? HTTPURLResponse else { throw GalleryUploadError.deliveryUnknown }
        guard (200...299).contains(httpResponse.statusCode) else {
            if httpResponse.statusCode == 429 {
                throw GalleryUploadError.rateLimited(Self.retryAfter(httpResponse.value(forHTTPHeaderField: "Retry-After")))
            }
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
                throw GalleryUploadError.httpStatus(httpResponse.statusCode)
            }
            throw GalleryUploadError.httpStatus(httpResponse.statusCode)
        }

        let uploadResponse: GalleryUploadResponse
        do {
            uploadResponse = try JSONDecoder().decode(GalleryUploadResponse.self, from: responseData)
        } catch {
            throw GalleryUploadError.deliveryUnknown
        }

        if let timing = uploadResponse.serverTiming {
            let stages = ["validationMs", "lockWaitMs", "rootFolderLookupMs", "folderLookupMs", "folderCreateMs",
                "folderInspectionMs", "manifestReadMs", "manifestCreateMs", "driveWriteMs", "totalMs"]
                + (0..<10).map { "imageCreate\($0)Ms" }
            for stage in stages {
                if let elapsed = timing[stage], elapsed.isFinite, elapsed >= 0 {
                    Self.performanceLogger.info("Gallery server stage=\(stage, privacy: .public) elapsedMs=\(elapsed)")
                }
            }
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

        guard Self.validateSuccessfulResponse(uploadResponse, expectedGalleryToken: payload.galleryToken, expectedGalleryURL: payload.galleryURL, expectedPhotoCount: payload.photos.count, expectedGIFIncluded: payload.gif != nil, expectedShareReceiptIncluded: payload.shareColorReceipt != nil),
              uploadResponse.schemaVersion == payload.schemaVersion,
              let galleryToken = uploadResponse.galleryToken,
              uploadResponse.galleryURL != nil else {
            throw GalleryUploadError.deliveryUnknown
        }

#if DEBUG
        let totalDuration = Date().timeIntervalSince(totalStart)
        debugLog("Gallery upload succeeded. uploadNetwork=\(String(format: "%.3f", networkDuration))s total=\(String(format: "%.3f", totalDuration))s responseBytes=\(responseData.count)")
#endif
        validationSucceeded = true
        // Always report the frozen URL (the one on the printed QR), never the backend's rebuilt one.
        return GalleryUploadResult(galleryToken: galleryToken, galleryURL: payload.galleryURL, status: GalleryUploadResultStatus(serverStatus: uploadResponse.status))
    }

    private func retryPendingGalleryWithBackoff(
        galleryToken: String,
        deviceToken: String,
        maxAttempts: Int, alreadyReconciled: Bool = false
    ) async throws -> GalleryUploadResult {
        let delays: [Duration] = [.seconds(2), .seconds(5), .seconds(10)]
        var lastError: Error?
        for attempt in 1...max(1, maxAttempts) {
            do {
                return try await uploadPendingGallery(galleryToken: galleryToken, deviceToken: deviceToken, priority: .recovery, alreadyReconciled: alreadyReconciled && attempt == 1)
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

    nonisolated static func retryAfter(_ value: String?, now: Date = Date()) -> TimeInterval {
        if let value, let seconds = TimeInterval(value), seconds.isFinite { return max(1, min(86400, seconds)) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let value, let date = formatter.date(from: value) { return max(1, min(86400, date.timeIntervalSince(now))) }
        return 60
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
