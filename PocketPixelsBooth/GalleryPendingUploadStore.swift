//
//  GalleryPendingUploadStore.swift
//  PocketPixelsBooth
//

import Foundation

nonisolated struct GalleryPendingUploadSummary: Equatable, Sendable, Identifiable {
    var id: String { galleryToken }
    let galleryToken: String
    let galleryURL: URL
    let sessionID: String
    let createdAt: String
    let deliveryState: GalleryDeliveryState
    let metrics: GalleryPreparedUploadMetrics
    let payloadSizeBytes: Int
    let retryAttemptCount: Int
    let lastAttemptAt: Date?
    let lastSafeError: String?
    var retryCategory: GalleryRetryCategory? = nil
    var nextAttemptAt: Date? = nil
    var needsAttention: Bool { retryCategory?.needsAttention == true }
}

nonisolated struct GalleryPendingUploadStore: @unchecked Sendable {
    // Also serializes legacy synchronous operator readers with background delivery mutations.
    private static let lock = NSRecursiveLock()
    private let fileManager: FileManager
    private let directoryURL: URL
    private let legacyDirectoryURL: URL

    init(fileManager: FileManager = .default, directoryURL: URL? = nil) throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        self.fileManager = fileManager
        if let directoryURL {
            self.directoryURL = directoryURL
            self.legacyDirectoryURL = directoryURL
        } else {
            let supportURL = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            self.directoryURL = supportURL.appendingPathComponent("PendingGalleryUploadQueueV3", isDirectory: true)
            self.legacyDirectoryURL = supportURL.appendingPathComponent("PendingGalleryUpload", isDirectory: true)
        }
        try ensureQueueDirectory()
    }

    func save(_ payload: GalleryPreparedUploadPayload, lastSafeError: String? = nil) throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        guard GalleryTokenGenerator.isValidGalleryToken(payload.galleryToken) else {
            throw GalleryUploadError.invalidGalleryToken
        }

        try ensureQueueDirectory()
        let finalURL = payloadDirectoryURL(for: payload.galleryToken)
        let existing = existingMetadata(for: payload.galleryToken)
        let metadata = GalleryPendingUploadMetadata(
            schemaVersion: payload.schemaVersion,
            galleryToken: payload.galleryToken,
            galleryURL: payload.galleryURL,
            sessionID: payload.sessionID,
            createdAt: payload.createdAt,
            photoFilenames: payload.photos.map(\.filename),
            receiptFilename: payload.colorReceipt.filename,
            thermalReceiptFilename: payload.thermalReceipt?.filename,
            gifFilename: payload.gif?.filename,
            metrics: payload.metrics,
            deliveryState: existing?.deliveryState ?? payload.deliveryState,
            retryAttemptCount: existing?.retryAttemptCount ?? 0,
            lastAttemptAt: existing?.lastAttemptAt,
            lastSafeError: lastSafeError,
            shareColorReceiptFilename: payload.shareColorReceipt?.filename, receiptVariants: payload.receiptVariants,
            retryCategory: existing?.retryCategory,
            nextAttemptAt: existing?.nextAttemptAt
        )

        if fileManager.fileExists(atPath: finalURL.path) {
            guard try storedPayload(at: finalURL, matches: payload) else {
                throw GalleryUploadError.conflictManualInspection("A pending gallery with this token already exists and does not match this session.")
            }
            let metadataURL = finalURL.appendingPathComponent(Self.metadataFilename)
            try JSONEncoder().encode(metadata).write(to: metadataURL, options: .atomic)
            try applyStorageAttributes(to: finalURL)
            return
        }

        let stagingURL = directoryURL.appendingPathComponent("staging-\(payload.galleryToken)-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: true)
        try applyStorageAttributes(to: stagingURL)

        do {
            for image in payload.photos + [payload.colorReceipt] + [payload.thermalReceipt, payload.gif, payload.shareColorReceipt].compactMap({ $0 }) {
                try image.data.write(to: stagingURL.appendingPathComponent(image.filename), options: .atomic)
            }

            let metadataData = try JSONEncoder().encode(metadata)
            try metadataData.write(to: stagingURL.appendingPathComponent(Self.metadataFilename), options: .atomic)
            try applyStorageAttributes(to: stagingURL)

            try fileManager.moveItem(at: stagingURL, to: finalURL)
            try applyStorageAttributes(to: finalURL)
        } catch {
            try? fileManager.removeItem(at: stagingURL)
            throw error
        }
    }

    func load() throws -> GalleryPreparedUploadPayload? {
        Self.lock.lock(); defer { Self.lock.unlock() }
        guard let token = try oldestQueuedToken() else {
            return nil
        }
        return try load(galleryToken: token)
    }

    func load(galleryToken: String) throws -> GalleryPreparedUploadPayload? {
        Self.lock.lock(); defer { Self.lock.unlock() }
        let metadataURL = payloadDirectoryURL(for: galleryToken).appendingPathComponent(Self.metadataFilename)
        guard fileManager.fileExists(atPath: metadataURL.path) else {
            return nil
        }

        guard !isLegacyMetadata(at: metadataURL) else {
            throw GalleryUploadError.stalePendingUpload
        }

        let decodedMetadata = try JSONDecoder().decode(GalleryPendingUploadMetadata.self, from: Data(contentsOf: metadataURL))
        let metadata = try migrateDebugGalleryURLIfNeeded(decodedMetadata, metadataURL: metadataURL)
        let baseURL = payloadDirectoryURL(for: metadata.galleryToken)
        let photos = try metadata.photoFilenames.map { filename in
            try loadImage(filename: filename, from: baseURL)
        }
        let receipt = try loadImage(filename: metadata.receiptFilename, from: baseURL)
        let thermalReceipt = try metadata.thermalReceiptFilename.map { try loadImage(filename: $0, from: baseURL) }
        let gif = try metadata.gifFilename.map { try loadImage(filename: $0, from: baseURL) }

        return GalleryPreparedUploadPayload(
            schemaVersion: metadata.schemaVersion,
            galleryToken: metadata.galleryToken,
            galleryURL: metadata.galleryURL,
            sessionID: metadata.sessionID,
            createdAt: metadata.createdAt,
            photos: photos,
            colorReceipt: receipt,
            thermalReceipt: thermalReceipt,
            gif: gif,
            metrics: metadata.metrics,
            deliveryState: metadata.deliveryState,
            shareColorReceipt: try metadata.shareColorReceiptFilename.map { try loadImage(filename: $0, from: baseURL) },
            receiptVariants: metadata.receiptVariants
        )
    }

    func summaries() throws -> [GalleryPendingUploadSummary] {
        Self.lock.lock(); defer { Self.lock.unlock() }
        return try queuedTokenDirectories().compactMap { directory in
            let metadataURL = directory.appendingPathComponent(Self.metadataFilename)
            guard fileManager.fileExists(atPath: metadataURL.path) else { return nil }
            let decodedMetadata = try JSONDecoder().decode(GalleryPendingUploadMetadata.self, from: Data(contentsOf: metadataURL))
            let metadata = try migrateDebugGalleryURLIfNeeded(decodedMetadata, metadataURL: metadataURL)
            return GalleryPendingUploadSummary(
                galleryToken: metadata.galleryToken,
                galleryURL: metadata.galleryURL,
                sessionID: metadata.sessionID,
                createdAt: metadata.createdAt,
                deliveryState: metadata.deliveryState,
                metrics: metadata.metrics,
                payloadSizeBytes: metadata.metrics.totalDecodedBytes,
                retryAttemptCount: metadata.retryAttemptCount,
                lastAttemptAt: metadata.lastAttemptAt,
                lastSafeError: metadata.lastSafeError,
                retryCategory: metadata.retryCategory, nextAttemptAt: metadata.nextAttemptAt
            )
        }
        .sorted { $0.createdAt < $1.createdAt }
    }

    func summary() throws -> GalleryPendingUploadSummary? {
        Self.lock.lock(); defer { Self.lock.unlock() }
        return try summaries().first
    }

    func updateDeliveryState(_ deliveryState: GalleryDeliveryState, galleryToken: String? = nil, lastSafeError: String? = nil) throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        let token = try galleryToken ?? oldestQueuedToken()
        guard let token else { return }
        try updateMetadata(token) { metadata in
            metadata.deliveryState = deliveryState
            metadata.lastSafeError = lastSafeError
        }
    }

    func recordFailure(galleryToken: String, error: Error, now: Date = Date()) throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        try updateMetadata(galleryToken) { metadata in
            let category = GalleryRetryCategory.classify(error, state: metadata.deliveryState)
            metadata.retryCategory = category
            let retryAfter: TimeInterval?
            if case GalleryUploadError.rateLimited(let delay) = error { retryAfter = delay }
            else if case GalleryPublicVerificationError.rateLimited(let delay) = error { retryAfter = delay } else { retryAfter = nil }
            metadata.nextAttemptAt = category.nextAttempt(at: now, attempts: metadata.retryAttemptCount, retryAfter: retryAfter)
            // Fixed descriptions only: backend response bodies can contain identities or tokens.
            metadata.lastSafeError = category.needsAttention
                ? "Delivery needs operator inspection in Gallery Setup. Photos are retained."
                : "Delivery is waiting (\(category.rawValue)). Photos are retained; automatic retry is scheduled."
        }
        NotificationCenter.default.post(name: .galleryQueueChanged, object: nil)
    }

    func requestRetry(galleryToken: String? = nil, now: Date = Date(), connectivityRestored: Bool = false) throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        for summary in try summaries() where galleryToken == nil || summary.galleryToken == galleryToken {
            // A connection signal cannot fix credentials or bypass a server rate limit.
            if connectivityRestored && (summary.needsAttention || summary.retryCategory == .rateLimited) { continue }
            if summary.retryCategory == .rateLimited, let deadline = summary.nextAttemptAt, deadline > now { continue }
            try updateMetadata(summary.galleryToken) { metadata in
                metadata.nextAttemptAt = now
                if !connectivityRestored { metadata.retryCategory = nil }
            }
        }
    }

    /// Metadata-only recovery: accepted galleries never need to reopen photograph files.
    func delivery(galleryToken: String) throws -> (target: GalleryVerificationTarget, state: GalleryDeliveryState)? {
        Self.lock.lock(); defer { Self.lock.unlock() }
        let url = payloadDirectoryURL(for: galleryToken).appendingPathComponent(Self.metadataFilename)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        guard !isLegacyMetadata(at: url) else { throw GalleryUploadError.stalePendingUpload }
        let decoded = try JSONDecoder().decode(GalleryPendingUploadMetadata.self, from: Data(contentsOf: url))
        let metadata = try migrateDebugGalleryURLIfNeeded(decoded, metadataURL: url)
        guard metadata.galleryToken == galleryToken else { throw GalleryUploadError.deliveryUnknown }
        let count = metadata.photoFilenames.count + 2 + [metadata.thermalReceiptFilename, metadata.gifFilename, metadata.shareColorReceiptFilename].compactMap { $0 }.count
        return (GalleryVerificationTarget(sessionID: metadata.sessionID, token: metadata.galleryToken, url: metadata.galleryURL,
            photoCount: metadata.photoFilenames.count, schemaVersion: metadata.schemaVersion, fileCount: count), metadata.deliveryState)
    }

    private func existingMetadata(for token: String) -> GalleryPendingUploadMetadata? {
        try? JSONDecoder().decode(GalleryPendingUploadMetadata.self,
            from: Data(contentsOf: payloadDirectoryURL(for: token).appendingPathComponent(Self.metadataFilename)))
    }

    private func updateMetadata(_ token: String, change: (inout GalleryPendingUploadMetadata) -> Void) throws {
        guard var metadata = existingMetadata(for: token) else {
            throw GalleryUploadError.configuration("Pending gallery metadata could not be read. Files are retained.")
        }
        change(&metadata)
        try JSONEncoder().encode(metadata).write(to: payloadDirectoryURL(for: token).appendingPathComponent(Self.metadataFilename), options: .atomic)
    }

    func recordAttempt(galleryToken: String) throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        let metadataURL = payloadDirectoryURL(for: galleryToken).appendingPathComponent(Self.metadataFilename)
        guard fileManager.fileExists(atPath: metadataURL.path) else {
            return
        }
        var metadata = try JSONDecoder().decode(GalleryPendingUploadMetadata.self, from: Data(contentsOf: metadataURL))
        metadata.retryAttemptCount += 1
        metadata.lastAttemptAt = Date()
        try JSONEncoder().encode(metadata).write(to: metadataURL, options: .atomic)
    }

    func clear(galleryToken: String) throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        let url = payloadDirectoryURL(for: galleryToken)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    func clear() throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        guard let token = try oldestQueuedToken() else { return }
        try clear(galleryToken: token)
    }

#if DEBUG
    func discardLocalPendingUpload() throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        guard let token = try oldestQueuedToken() else {
            return
        }
        try clear(galleryToken: token)
        try ensureQueueDirectory()
    }
#endif

    func hasLegacyPendingUpload() -> Bool {
        Self.lock.lock(); defer { Self.lock.unlock() }
        return isLegacyMetadata(at: legacyDirectoryURL.appendingPathComponent(Self.metadataFilename))
    }

    private func ensureQueueDirectory() throws {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try applyStorageAttributes(to: directoryURL)
    }

    private func payloadDirectoryURL(for galleryToken: String) -> URL {
        directoryURL.appendingPathComponent(galleryToken, isDirectory: true)
    }

    private func queuedTokenDirectories() throws -> [URL] {
        guard fileManager.fileExists(atPath: directoryURL.path) else { return [] }
        return try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.creationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ).filter { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true &&
            GalleryTokenGenerator.isValidGalleryToken(url.lastPathComponent)
        }
    }

    private func oldestQueuedToken() throws -> String? {
        try summaries().first?.galleryToken
    }

    private func loadImage(filename: String, from baseURL: URL) throws -> GalleryStoredUploadImage {
        let data = try Data(contentsOf: baseURL.appendingPathComponent(filename))
        let mimeType = filename.hasSuffix(".png") ? "image/png" : (filename.hasSuffix(".gif") ? "image/gif" : "image/jpeg")
        return GalleryStoredUploadImage(filename: filename, mimeType: mimeType, data: data)
    }

    private func storedPayload(at directory: URL, matches payload: GalleryPreparedUploadPayload) throws -> Bool {
        let metadataURL = directory.appendingPathComponent(Self.metadataFilename)
        guard fileManager.fileExists(atPath: metadataURL.path),
              !isLegacyMetadata(at: metadataURL) else {
            return false
        }

        let decodedMetadata = try JSONDecoder().decode(GalleryPendingUploadMetadata.self, from: Data(contentsOf: metadataURL))
        let metadata = try migrateDebugGalleryURLIfNeeded(decodedMetadata, metadataURL: metadataURL)
        guard metadata.schemaVersion == payload.schemaVersion,
              metadata.galleryToken == payload.galleryToken,
              metadata.galleryURL == payload.galleryURL,
              metadata.sessionID == payload.sessionID,
              metadata.createdAt == payload.createdAt,
              metadata.photoFilenames == payload.photos.map(\.filename),
              metadata.receiptFilename == payload.colorReceipt.filename,
              metadata.shareColorReceiptFilename == payload.shareColorReceipt?.filename,
              metadata.receiptVariants == payload.receiptVariants,
              metadata.thermalReceiptFilename == payload.thermalReceipt?.filename,
              metadata.gifFilename == payload.gif?.filename else {
            return false
        }

        for image in payload.photos + [payload.colorReceipt] + [payload.thermalReceipt, payload.gif, payload.shareColorReceipt].compactMap({ $0 }) {
            let storedData = try Data(contentsOf: directory.appendingPathComponent(image.filename))
            guard storedData == image.data else {
                return false
            }
        }
        return true
    }

    private func payloadSize(at directory: URL) -> Int {
        guard let enumerator = fileManager.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total = 0
        for case let fileURL as URL in enumerator {
            total += (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        return total
    }

    private func applyStorageAttributes(to url: URL) throws {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try mutableURL.setResourceValues(values)
#if os(iOS)
        try? fileManager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
#endif
    }

    private func isLegacyMetadata(at metadataURL: URL) -> Bool {
        guard fileManager.fileExists(atPath: metadataURL.path),
              let data = try? Data(contentsOf: metadataURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }

        return object["schemaVersion"] as? Int == 1
            && object["galleryToken"] == nil
            && object["galleryURL"] == nil
    }

    private func migrateDebugGalleryURLIfNeeded(_ metadata: GalleryPendingUploadMetadata, metadataURL: URL) throws -> GalleryPendingUploadMetadata {
#if DEBUG
        guard metadata.galleryURL.host()?.lowercased() == "gallery.example.com" else {
            return metadata
        }
        guard GalleryTokenGenerator.isValidGalleryToken(metadata.galleryToken) else {
            throw GalleryUploadError.invalidGalleryToken
        }

        let customerBaseURL = try CustomerGalleryConfiguration.load().baseURL
        let migratedGalleryURL = try GalleryURLBuilder.makeGalleryURL(
            customerGalleryBaseURL: customerBaseURL,
            galleryToken: metadata.galleryToken
        )
        let migratedMetadata = GalleryPendingUploadMetadata(
            schemaVersion: metadata.schemaVersion,
            galleryToken: metadata.galleryToken,
            galleryURL: migratedGalleryURL,
            sessionID: metadata.sessionID,
            createdAt: metadata.createdAt,
            photoFilenames: metadata.photoFilenames,
            receiptFilename: metadata.receiptFilename,
            thermalReceiptFilename: metadata.thermalReceiptFilename,
            gifFilename: metadata.gifFilename,
            metrics: metadata.metrics,
            deliveryState: metadata.deliveryState,
            retryAttemptCount: metadata.retryAttemptCount,
            lastAttemptAt: metadata.lastAttemptAt,
            lastSafeError: metadata.lastSafeError,
            shareColorReceiptFilename: metadata.shareColorReceiptFilename, receiptVariants: metadata.receiptVariants,
            retryCategory: metadata.retryCategory, nextAttemptAt: metadata.nextAttemptAt
        )
        try JSONEncoder().encode(migratedMetadata).write(to: metadataURL, options: .atomic)
        return migratedMetadata
#else
        return metadata
#endif
    }

    private static let metadataFilename = "metadata.json"
}

nonisolated private struct GalleryPendingUploadMetadata: Codable {
    let schemaVersion: Int
    let galleryToken: String
    let galleryURL: URL
    let sessionID: String
    let createdAt: String
    let photoFilenames: [String]
    let receiptFilename: String
    let shareColorReceiptFilename: String?
    let receiptVariants: GalleryReceiptVariants?
    let thermalReceiptFilename: String?
    let gifFilename: String?
    let metrics: GalleryPreparedUploadMetrics
    var deliveryState: GalleryDeliveryState
    var retryAttemptCount: Int
    var lastAttemptAt: Date?
    var lastSafeError: String?
    var retryCategory: GalleryRetryCategory?
    var nextAttemptAt: Date?

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case galleryToken
        case galleryURL
        case sessionID
        case createdAt
        case photoFilenames
        case receiptFilename
        case thermalReceiptFilename, shareColorReceiptFilename, receiptVariants
        case gifFilename
        case metrics
        case deliveryState
        case retryAttemptCount
        case lastAttemptAt
        case lastSafeError, retryCategory, nextAttemptAt
    }

    init(
        schemaVersion: Int,
        galleryToken: String,
        galleryURL: URL,
        sessionID: String,
        createdAt: String,
        photoFilenames: [String],
        receiptFilename: String,
        thermalReceiptFilename: String?,
        gifFilename: String?,
        metrics: GalleryPreparedUploadMetrics,
        deliveryState: GalleryDeliveryState,
        retryAttemptCount: Int,
        lastAttemptAt: Date?,
        lastSafeError: String?,
        shareColorReceiptFilename: String? = nil, receiptVariants: GalleryReceiptVariants? = nil,
        retryCategory: GalleryRetryCategory? = nil, nextAttemptAt: Date? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.galleryToken = galleryToken
        self.galleryURL = galleryURL
        self.sessionID = sessionID
        self.createdAt = createdAt
        self.photoFilenames = photoFilenames
        self.receiptFilename = receiptFilename
        self.thermalReceiptFilename = thermalReceiptFilename
        self.gifFilename = gifFilename
        self.metrics = metrics
        self.deliveryState = deliveryState
        self.retryAttemptCount = retryAttemptCount
        self.lastAttemptAt = lastAttemptAt
        self.lastSafeError = lastSafeError
        self.retryCategory = retryCategory; self.nextAttemptAt = nextAttemptAt
        self.shareColorReceiptFilename = shareColorReceiptFilename; self.receiptVariants = receiptVariants
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        galleryToken = try container.decode(String.self, forKey: .galleryToken)
        galleryURL = try container.decode(URL.self, forKey: .galleryURL)
        sessionID = try container.decode(String.self, forKey: .sessionID)
        createdAt = try container.decode(String.self, forKey: .createdAt)
        photoFilenames = try container.decode([String].self, forKey: .photoFilenames)
        receiptFilename = try container.decode(String.self, forKey: .receiptFilename)
        shareColorReceiptFilename = try container.decodeIfPresent(String.self, forKey: .shareColorReceiptFilename)
        receiptVariants = try container.decodeIfPresent(GalleryReceiptVariants.self, forKey: .receiptVariants)
        thermalReceiptFilename = try container.decodeIfPresent(String.self, forKey: .thermalReceiptFilename)
        gifFilename = try container.decodeIfPresent(String.self, forKey: .gifFilename)
        metrics = try container.decode(GalleryPreparedUploadMetrics.self, forKey: .metrics)
        deliveryState = try container.decode(GalleryDeliveryState.self, forKey: .deliveryState)
        retryAttemptCount = try container.decodeIfPresent(Int.self, forKey: .retryAttemptCount) ?? 0
        lastAttemptAt = try container.decodeIfPresent(Date.self, forKey: .lastAttemptAt)
        lastSafeError = try container.decodeIfPresent(String.self, forKey: .lastSafeError)
        retryCategory = try container.decodeIfPresent(GalleryRetryCategory.self, forKey: .retryCategory)
        nextAttemptAt = try container.decodeIfPresent(Date.self, forKey: .nextAttemptAt)
    }
}

/// One utility executor for blocking gallery I/O, shared across service instances.
actor GalleryDiskIO {
    static let shared = GalleryDiskIO()
    func run<T: Sendable>(_ operation: @Sendable () throws -> T) throws -> T { try operation() }
}
