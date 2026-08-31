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
        let stagingURL = directoryURL.appendingPathComponent("staging-\(payload.galleryToken)-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: true)
        try applyStorageAttributes(to: stagingURL)

        do {
            for image in payload.photos + [payload.receipt] {
                try image.data.write(to: stagingURL.appendingPathComponent(image.filename), options: .atomic)
            }

            let metadata = GalleryPendingUploadMetadata(
                schemaVersion: payload.schemaVersion,
                galleryToken: payload.galleryToken,
                galleryURL: payload.galleryURL,
                sessionID: payload.sessionID,
                createdAt: payload.createdAt,
                photoFilenames: payload.photos.map(\.filename),
                receiptFilename: payload.receipt.filename,
                metrics: payload.metrics,
                deliveryState: payload.deliveryState,
                lastSafeError: lastSafeError
            )
            let metadataData = try JSONEncoder().encode(metadata)
            try metadataData.write(to: stagingURL.appendingPathComponent(Self.metadataFilename), options: .atomic)
            try applyStorageAttributes(to: stagingURL)

            if fileManager.fileExists(atPath: finalURL.path) {
                try fileManager.removeItem(at: finalURL)
            }
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

        return GalleryPreparedUploadPayload(
            schemaVersion: metadata.schemaVersion,
            galleryToken: metadata.galleryToken,
            galleryURL: metadata.galleryURL,
            sessionID: metadata.sessionID,
            createdAt: metadata.createdAt,
            photos: photos,
            receipt: receipt,
            metrics: metadata.metrics,
            deliveryState: metadata.deliveryState
        )
    }

    func summaries() throws -> [GalleryPendingUploadSummary] {
        if hasLegacyPendingUpload() {
            throw GalleryUploadError.stalePendingUpload
        }

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
            receipt: payload.receipt,
            metrics: payload.metrics,
            deliveryState: deliveryState
        )
        try save(payload, lastSafeError: lastSafeError)
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
        if fileManager.fileExists(atPath: directoryURL.path) {
            try fileManager.removeItem(at: directoryURL)
        }
        if legacyDirectoryURL != directoryURL, fileManager.fileExists(atPath: legacyDirectoryURL.path) {
            try fileManager.removeItem(at: legacyDirectoryURL)
        }
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
        return GalleryStoredUploadImage(filename: filename, mimeType: "image/jpeg", data: data)
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
            metrics: metadata.metrics,
            deliveryState: metadata.deliveryState,
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
    let metrics: GalleryPreparedUploadMetrics
    let deliveryState: GalleryDeliveryState
    let lastSafeError: String?
}
