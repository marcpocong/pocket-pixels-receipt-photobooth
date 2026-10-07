//
//  GalleryPendingUploadStore.swift
//  PocketPixelsBooth
//

import Foundation

struct GalleryPendingUploadSummary: Equatable, Sendable, Identifiable {
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
}

struct GalleryPendingUploadStore: Sendable {
    private let fileManager: FileManager
    private let directoryURL: URL
    private let legacyDirectoryURL: URL

    init(fileManager: FileManager = .default, directoryURL: URL? = nil) throws {
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
        guard GalleryTokenGenerator.isValidGalleryToken(payload.galleryToken) else {
            throw GalleryUploadError.invalidGalleryToken
        }

        try ensureQueueDirectory()
        let finalURL = payloadDirectoryURL(for: payload.galleryToken)
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
            deliveryState: payload.deliveryState,
            retryAttemptCount: existingRetryAttemptCount(for: payload.galleryToken),
            lastAttemptAt: existingLastAttemptAt(for: payload.galleryToken),
            lastSafeError: lastSafeError
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
            for image in payload.photos + [payload.colorReceipt] + [payload.thermalReceipt, payload.gif].compactMap({ $0 }) {
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
        guard let token = try oldestQueuedToken() else {
            return nil
        }
        return try load(galleryToken: token)
    }

    func load(galleryToken: String) throws -> GalleryPreparedUploadPayload? {
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
            deliveryState: metadata.deliveryState
        )
    }

    func summaries() throws -> [GalleryPendingUploadSummary] {
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
                payloadSizeBytes: payloadSize(at: directory),
                retryAttemptCount: metadata.retryAttemptCount,
                lastAttemptAt: metadata.lastAttemptAt,
                lastSafeError: metadata.lastSafeError
            )
        }
        .sorted { $0.createdAt < $1.createdAt }
    }

    func summary() throws -> GalleryPendingUploadSummary? {
        try summaries().first
    }

    func updateDeliveryState(_ deliveryState: GalleryDeliveryState, galleryToken: String? = nil, lastSafeError: String? = nil) throws {
        let token = try galleryToken ?? oldestQueuedToken()
        guard let token, var payload = try load(galleryToken: token) else {
            return
        }
        payload = GalleryPreparedUploadPayload(
            schemaVersion: payload.schemaVersion,
            galleryToken: payload.galleryToken,
            galleryURL: payload.galleryURL,
            sessionID: payload.sessionID,
            createdAt: payload.createdAt,
            photos: payload.photos,
            colorReceipt: payload.colorReceipt,
            thermalReceipt: payload.thermalReceipt,
            gif: payload.gif,
            metrics: payload.metrics,
            deliveryState: deliveryState
        )
        try save(payload, lastSafeError: lastSafeError)
    }

    func recordAttempt(galleryToken: String) throws {
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
        let url = payloadDirectoryURL(for: galleryToken)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    func clear() throws {
        guard let token = try oldestQueuedToken() else { return }
        try clear(galleryToken: token)
    }

#if DEBUG
    func discardLocalPendingUpload() throws {
        guard let token = try oldestQueuedToken() else {
            return
        }
        try clear(galleryToken: token)
        try ensureQueueDirectory()
    }
#endif

    func hasLegacyPendingUpload() -> Bool {
        isLegacyMetadata(at: legacyDirectoryURL.appendingPathComponent(Self.metadataFilename))
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
              metadata.thermalReceiptFilename == payload.thermalReceipt?.filename,
              metadata.gifFilename == payload.gif?.filename else {
            return false
        }

        for image in payload.photos + [payload.colorReceipt] + [payload.thermalReceipt, payload.gif].compactMap({ $0 }) {
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

    private func existingRetryAttemptCount(for galleryToken: String) -> Int {
        guard let metadata = try? JSONDecoder().decode(
            GalleryPendingUploadMetadata.self,
            from: Data(contentsOf: payloadDirectoryURL(for: galleryToken).appendingPathComponent(Self.metadataFilename))
        ) else {
            return 0
        }
        return metadata.retryAttemptCount
    }

    private func existingLastAttemptAt(for galleryToken: String) -> Date? {
        guard let metadata = try? JSONDecoder().decode(
            GalleryPendingUploadMetadata.self,
            from: Data(contentsOf: payloadDirectoryURL(for: galleryToken).appendingPathComponent(Self.metadataFilename))
        ) else {
            return nil
        }
        return metadata.lastAttemptAt
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
            lastSafeError: metadata.lastSafeError
        )
        try JSONEncoder().encode(migratedMetadata).write(to: metadataURL, options: .atomic)
        return migratedMetadata
#else
        return metadata
#endif
    }

    private static let metadataFilename = "metadata.json"
}

private struct GalleryPendingUploadMetadata: Codable {
    let schemaVersion: Int
    let galleryToken: String
    let galleryURL: URL
    let sessionID: String
    let createdAt: String
    let photoFilenames: [String]
    let receiptFilename: String
    let thermalReceiptFilename: String?
    let gifFilename: String?
    let metrics: GalleryPreparedUploadMetrics
    let deliveryState: GalleryDeliveryState
    var retryAttemptCount: Int
    var lastAttemptAt: Date?
    let lastSafeError: String?

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case galleryToken
        case galleryURL
        case sessionID
        case createdAt
        case photoFilenames
        case receiptFilename
        case thermalReceiptFilename
        case gifFilename
        case metrics
        case deliveryState
        case retryAttemptCount
        case lastAttemptAt
        case lastSafeError
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
        lastSafeError: String?
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
        thermalReceiptFilename = try container.decodeIfPresent(String.self, forKey: .thermalReceiptFilename)
        gifFilename = try container.decodeIfPresent(String.self, forKey: .gifFilename)
        metrics = try container.decode(GalleryPreparedUploadMetrics.self, forKey: .metrics)
        deliveryState = try container.decode(GalleryDeliveryState.self, forKey: .deliveryState)
        retryAttemptCount = try container.decodeIfPresent(Int.self, forKey: .retryAttemptCount) ?? 0
        lastAttemptAt = try container.decodeIfPresent(Date.self, forKey: .lastAttemptAt)
        lastSafeError = try container.decodeIfPresent(String.self, forKey: .lastSafeError)
    }
}
