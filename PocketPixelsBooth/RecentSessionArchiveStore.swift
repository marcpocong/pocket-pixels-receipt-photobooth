//
//  RecentSessionArchiveStore.swift
//  PocketPixelsBooth
//

import CryptoKit
import Foundation

struct RecentSessionArchiveSummary: Identifiable, Equatable, Sendable {
    var id: String { archiveID }

    let archiveID: String
    let sessionIdentifier: String
    let createdAt: Date
    let format: BoothFormat
    let eventName: String?
    let eventLocation: String?
    let photoCount: Int
    let receiptWidth: Int
    let receiptHeight: Int
    let estimatedLengthMillimeters: Double
    let rasterFingerprint: String
    let thumbnailFilenames: [String]
    let lastReprintedAt: Date?
    let reprintCount: Int
    let payloadSizeBytes: Int
    var eventRunID: String? = nil
    var eventDesignID: String? = nil
}

struct RecentSessionArchive: Sendable {
    let summary: RecentSessionArchiveSummary
    let galleryToken: String
    let galleryURL: URL
    let eventProfile: EventProfile?
    let receiptPreviewPNGData: Data
    let thermalPreviewPNGData: Data
    let thumbnailData: [Data]
    let rasterizedImage: ThermalRasterizedImage
    /// Frozen Passport keepsake data stored locally with the archive; never uploaded.
    var passport: PassportSessionData? = nil
    var receiptPrintOptions: ReceiptPrintOptions? = nil
}

struct RecentSessionArchivePayload: Sendable {
    let committedSession: CommittedGallerySession
    let composedReceipt: ComposedReceipt
    let receiptPreviewPNGData: Data
    let thermalPreviewPNGData: Data
    let rasterizedImage: ThermalRasterizedImage
    let photoThumbnailData: [Data]
    var eventRunID: String? = nil
    var eventDesignID: String? = nil
}

enum RecentSessionArchiveError: Error, LocalizedError, Equatable {
    case invalidArchiveID
    case archiveNotFound
    case conflictingArchive
    case corruptedArchive(String)

    var errorDescription: String? {
        switch self {
        case .invalidArchiveID:
            "Archived session identity is invalid."
        case .archiveNotFound:
            "This archived session is no longer available."
        case .conflictingArchive:
            "An archived session with this identity already exists but does not match this receipt."
        case .corruptedArchive(let message):
            "This archived session cannot be loaded. \(message)"
        }
    }
}

nonisolated struct RecentSessionArchiveStore: Sendable {
    static let schemaVersion = 1
    static let retentionAge: TimeInterval = 7 * 24 * 60 * 60
    static let retentionCount = 250

    nonisolated(unsafe) private let fileManager: FileManager
    private let directoryURL: URL

    nonisolated init(fileManager: FileManager = .default, directoryURL: URL? = nil) throws {
        self.fileManager = fileManager
        if let directoryURL {
            self.directoryURL = directoryURL
        } else {
            let supportURL = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            self.directoryURL = supportURL.appendingPathComponent("RecentSessionArchiveV1", isDirectory: true)
        }

        try ensureArchiveDirectory()
        // A concurrent archive save may own a staging directory; reads must not remove it.
        // Event archives are retained until an explicit, delivery-aware cleanup is available.
    }

    nonisolated var storagePath: String {
        directoryURL.path
    }

    nonisolated func save(_ payload: RecentSessionArchivePayload) throws {
        let archiveID = archiveID(for: payload.committedSession)
        guard isValidArchiveID(archiveID) else {
            throw RecentSessionArchiveError.invalidArchiveID
        }

        try ensureArchiveDirectory()
        try validateRaster(payload.rasterizedImage)

        let finalURL = archiveDirectoryURL(for: archiveID)
        let metadata = metadata(for: payload, archiveID: archiveID)

        if fileManager.fileExists(atPath: finalURL.path) {
            guard try storedArchive(at: finalURL, matches: metadata, payload: payload) else {
                throw RecentSessionArchiveError.conflictingArchive
            }
            return
        }

        let stagingURL = directoryURL.appendingPathComponent("staging-\(archiveID)-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: true)
        try applyStorageAttributes(to: stagingURL)

        do {
            // The frozen reprint payload and metadata are flushed to stable storage before the
            // archive becomes visible, so a committed archive is always complete.
            try DurableFileWriter.write(payload.receiptPreviewPNGData, to: stagingURL.appendingPathComponent(Self.receiptPreviewFilename), fileManager: fileManager)
            try DurableFileWriter.write(payload.thermalPreviewPNGData, to: stagingURL.appendingPathComponent(Self.thermalPreviewFilename), fileManager: fileManager)
            try DurableFileWriter.write(payload.rasterizedImage.rasterData, to: stagingURL.appendingPathComponent(Self.rasterDataFilename), fileManager: fileManager)
            try DurableFileWriter.write(payload.rasterizedImage.rasterCommand, to: stagingURL.appendingPathComponent(Self.rasterCommandFilename), fileManager: fileManager)

            for (index, thumbnailData) in payload.photoThumbnailData.enumerated() {
                try thumbnailData.write(to: stagingURL.appendingPathComponent(Self.thumbnailFilename(index: index)), options: .atomic)
            }

            let metadataData = try JSONEncoder.archiveEncoder.encode(metadata)
            try DurableFileWriter.write(metadataData, to: stagingURL.appendingPathComponent(Self.metadataFilename), fileManager: fileManager)
            try validateArchive(at: stagingURL)
            try applyStorageAttributes(to: stagingURL)
            try fileManager.moveItem(at: stagingURL, to: finalURL)
            try applyStorageAttributes(to: finalURL)
            // Never automatically remove customer archives during an event.
        } catch {
            try? fileManager.removeItem(at: stagingURL)
            throw error
        }
    }

    nonisolated func summaries(includePayloadSize: Bool = true) throws -> [RecentSessionArchiveSummary] {
        try archiveDirectories().compactMap { directory in
            do {
                try Task.checkCancellation()
                let metadata = try loadMetadata(from: directory)
                return RecentSessionArchiveSummary(
                    archiveID: metadata.archiveID,
                    sessionIdentifier: metadata.sessionIdentifier,
                    createdAt: metadata.createdAt,
                    format: metadata.format,
                    eventName: metadata.eventName,
                    eventLocation: metadata.eventLocation,
                    photoCount: metadata.photoCount,
                    receiptWidth: metadata.receiptWidth,
                    receiptHeight: metadata.receiptHeight,
                    estimatedLengthMillimeters: metadata.estimatedLengthMillimeters,
                    rasterFingerprint: metadata.rasterFingerprint,
                    thumbnailFilenames: metadata.thumbnailFilenames,
                    lastReprintedAt: metadata.lastReprintedAt,
                    reprintCount: metadata.reprintCount,
                    payloadSizeBytes: includePayloadSize ? payloadSize(at: directory) : 0,
                    eventRunID: metadata.eventRunID,
                    eventDesignID: metadata.eventDesignID
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                return RecentSessionArchiveSummary(
                    archiveID: directory.lastPathComponent,
                    sessionIdentifier: "Unreadable archive",
                    createdAt: .distantPast,
                    format: .solo,
                    eventName: "This archived session cannot be loaded.",
                    eventLocation: nil,
                    photoCount: 0,
                    receiptWidth: 0,
                    receiptHeight: 0,
                    estimatedLengthMillimeters: 0,
                    rasterFingerprint: "CORRUPT",
                    thumbnailFilenames: [],
                    lastReprintedAt: nil,
                    reprintCount: 0,
                    payloadSizeBytes: includePayloadSize ? payloadSize(at: directory) : 0
                )
            }
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    nonisolated func summary(archiveID: String) throws -> RecentSessionArchiveSummary? {
        guard isValidArchiveID(archiveID) else { throw RecentSessionArchiveError.invalidArchiveID }
        let directory = archiveDirectoryURL(for: archiveID)
        guard fileManager.fileExists(atPath: directory.path) else { return nil }
        let m = try loadMetadata(from: directory)
        return RecentSessionArchiveSummary(archiveID: m.archiveID, sessionIdentifier: m.sessionIdentifier, createdAt: m.createdAt,
            format: m.format, eventName: m.eventName, eventLocation: m.eventLocation, photoCount: m.photoCount,
            receiptWidth: m.receiptWidth, receiptHeight: m.receiptHeight, estimatedLengthMillimeters: m.estimatedLengthMillimeters,
            rasterFingerprint: m.rasterFingerprint, thumbnailFilenames: m.thumbnailFilenames, lastReprintedAt: m.lastReprintedAt,
            reprintCount: m.reprintCount, payloadSizeBytes: 0, eventRunID: m.eventRunID, eventDesignID: m.eventDesignID)
    }

    nonisolated func load(archiveID: String) throws -> RecentSessionArchive {
        guard isValidArchiveID(archiveID) else {
            throw RecentSessionArchiveError.invalidArchiveID
        }

        let directory = archiveDirectoryURL(for: archiveID)
        guard fileManager.fileExists(atPath: directory.path) else {
            throw RecentSessionArchiveError.archiveNotFound
        }

        let metadata = try loadMetadata(from: directory)
        let receiptPreview = try Data(contentsOf: directory.appendingPathComponent(Self.receiptPreviewFilename))
        let thermalPreview = try Data(contentsOf: directory.appendingPathComponent(Self.thermalPreviewFilename))
        let rasterData = try Data(contentsOf: directory.appendingPathComponent(Self.rasterDataFilename))
        let rasterCommand = try Data(contentsOf: directory.appendingPathComponent(Self.rasterCommandFilename))
        guard rasterData.count == metadata.rasterDataByteCount,
              rasterCommand.count == metadata.rasterCommandByteCount else {
            throw RecentSessionArchiveError.corruptedArchive("Raster byte counts do not match metadata.")
        }

        let rasterizedImage = ThermalRasterizedImage(
            width: metadata.receiptWidth,
            height: metadata.receiptHeight,
            widthBytes: metadata.rasterWidthBytes,
            previewPNGData: thermalPreview,
            rasterData: rasterData,
            rasterCommand: rasterCommand,
            sanitizationReport: metadata.sanitizationReport,
            yL: metadata.yL,
            yH: metadata.yH
        )
        try validateRaster(rasterizedImage)

        let fingerprint = Self.rasterFingerprint(for: rasterizedImage)
        guard fingerprint == metadata.rasterFingerprint else {
            throw RecentSessionArchiveError.corruptedArchive("Raster fingerprint does not match metadata.")
        }

        let thumbnails = metadata.thumbnailFilenames.compactMap { filename in
            try? Data(contentsOf: directory.appendingPathComponent(filename))
        }

        let summary = RecentSessionArchiveSummary(
            archiveID: metadata.archiveID,
            sessionIdentifier: metadata.sessionIdentifier,
            createdAt: metadata.createdAt,
            format: metadata.format,
            eventName: metadata.eventName,
            eventLocation: metadata.eventLocation,
            photoCount: metadata.photoCount,
            receiptWidth: metadata.receiptWidth,
            receiptHeight: metadata.receiptHeight,
            estimatedLengthMillimeters: metadata.estimatedLengthMillimeters,
            rasterFingerprint: metadata.rasterFingerprint,
            thumbnailFilenames: metadata.thumbnailFilenames,
            lastReprintedAt: metadata.lastReprintedAt,
            reprintCount: metadata.reprintCount,
            payloadSizeBytes: payloadSize(at: directory),
            eventRunID: metadata.eventRunID,
            eventDesignID: metadata.eventDesignID
        )

        return RecentSessionArchive(
            summary: summary,
            galleryToken: metadata.galleryToken,
            galleryURL: metadata.galleryURL,
            eventProfile: metadata.eventProfile,
            receiptPreviewPNGData: receiptPreview,
            thermalPreviewPNGData: thermalPreview,
            thumbnailData: thumbnails,
            rasterizedImage: rasterizedImage,
            passport: metadata.passport,
            receiptPrintOptions: metadata.receiptPrintOptions
        )
    }

    /// Adds photo thumbnails to an already committed archive. Thumbnails are display-only and are
    /// written after the durable print payload, so a failure here never affects reprints.
    /// Idempotent: an archive that already lists thumbnails is left unchanged.
    nonisolated func attachThumbnails(archiveID: String, thumbnails: [Data]) throws {
        guard isValidArchiveID(archiveID) else {
            throw RecentSessionArchiveError.invalidArchiveID
        }
        let directory = archiveDirectoryURL(for: archiveID)
        guard fileManager.fileExists(atPath: directory.path) else {
            throw RecentSessionArchiveError.archiveNotFound
        }
        var metadata = try loadMetadata(from: directory)
        guard metadata.thumbnailFilenames.isEmpty, !thumbnails.isEmpty else { return }
        let filenames = thumbnails.indices.map { Self.thumbnailFilename(index: $0) }
        for (filename, data) in zip(filenames, thumbnails) {
            try data.write(to: directory.appendingPathComponent(filename), options: .atomic)
        }
        metadata.thumbnailFilenames = filenames
        try DurableFileWriter.write(JSONEncoder.archiveEncoder.encode(metadata), to: directory.appendingPathComponent(Self.metadataFilename), fileManager: fileManager)
    }

    /// True when a complete, loadable archive for this session already exists.
    nonisolated func containsCommittedArchive(galleryToken: String) -> Bool {
        (try? load(archiveID: galleryToken)) != nil
    }

    nonisolated func markReprinted(archiveID: String, date: Date = Date(), copies: Int) throws {
        guard isValidArchiveID(archiveID) else {
            throw RecentSessionArchiveError.invalidArchiveID
        }

        let directory = archiveDirectoryURL(for: archiveID)
        var metadata = try loadMetadata(from: directory)
        metadata.lastReprintedAt = date
        metadata.reprintCount += max(0, copies)
        try JSONEncoder.archiveEncoder.encode(metadata).write(to: directory.appendingPathComponent(Self.metadataFilename), options: .atomic)
    }

    nonisolated func delete(archiveID: String) throws {
        guard isValidArchiveID(archiveID) else {
            throw RecentSessionArchiveError.invalidArchiveID
        }

        let directory = archiveDirectoryURL(for: archiveID)
        guard fileManager.fileExists(atPath: directory.path) else { return }
        try fileManager.removeItem(at: directory)
    }

    nonisolated func clearAll(excluding excludedArchiveIDs: Set<String> = []) throws {
        for directory in try archiveDirectories() where !excludedArchiveIDs.contains(directory.lastPathComponent) {
            try fileManager.removeItem(at: directory)
        }
    }

    nonisolated func thumbnailData(archiveID: String, filename: String) -> Data? {
        guard isValidArchiveID(archiveID), isSafeFilename(filename) else {
            return nil
        }

        return try? Data(contentsOf: archiveDirectoryURL(for: archiveID).appendingPathComponent(filename))
    }

    nonisolated func prune(excluding excludedArchiveIDs: Set<String> = []) throws {
        let now = Date()
        var entries = try archiveDirectories().compactMap { directory -> (url: URL, metadata: RecentSessionArchiveMetadata)? in
            guard let metadata = try? loadMetadata(from: directory) else { return nil }
            return (url: directory, metadata: metadata)
        }

        let expired = entries.filter { entry in
            !excludedArchiveIDs.contains(entry.url.lastPathComponent)
                && now.timeIntervalSince(entry.metadata.createdAt) > Self.retentionAge
        }
        for entry in expired {
            try? fileManager.removeItem(at: entry.url)
        }

        let expiredURLs = Set(expired.map(\.url))
        entries = entries
            .filter { !expiredURLs.contains($0.url) }
            .sorted { $0.metadata.createdAt > $1.metadata.createdAt }

        for entry in entries.dropFirst(Self.retentionCount) where !excludedArchiveIDs.contains(entry.url.lastPathComponent) {
            try? fileManager.removeItem(at: entry.url)
        }
    }

    nonisolated static func rasterFingerprint(for rasterizedImage: ThermalRasterizedImage) -> String {
        let payload = ThermalImageRasterizer.receiptPrintHeading()
            + rasterizedImage.rasterCommand
            + ThermalImageRasterizer.photoTestFinishing()
        return SHA256.hash(data: payload)
            .prefix(6)
            .map { String(format: "%02X", $0) }
            .joined()
    }

    private func archiveID(for session: CommittedGallerySession) -> String {
        session.galleryToken
    }

    private func metadata(for payload: RecentSessionArchivePayload, archiveID: String) -> RecentSessionArchiveMetadata {
        let raster = payload.rasterizedImage
        let eventProfile = payload.committedSession.eventProfile?.normalized()
        return RecentSessionArchiveMetadata(
            schemaVersion: Self.schemaVersion,
            archiveID: archiveID,
            sessionIdentifier: payload.committedSession.sessionIdentifier,
            createdAt: payload.committedSession.createdAt,
            galleryToken: payload.committedSession.galleryToken,
            galleryURL: payload.committedSession.galleryURL,
            format: payload.committedSession.format,
            eventProfile: eventProfile,
            eventName: eventProfile?.eventName.nilIfEmpty,
            eventLocation: eventProfile?.location.nilIfEmpty,
            photoCount: payload.committedSession.photos.count,
            receiptWidth: payload.composedReceipt.width,
            receiptHeight: payload.composedReceipt.height,
            estimatedLengthMillimeters: payload.composedReceipt.estimatedLengthMillimeters,
            rasterWidthBytes: raster.widthBytes,
            rasterDataByteCount: raster.rasterData.count,
            rasterCommandByteCount: raster.rasterCommand.count,
            rasterFingerprint: Self.rasterFingerprint(for: raster),
            yL: raster.yL,
            yH: raster.yH,
            sanitizationReport: raster.sanitizationReport,
            thumbnailFilenames: payload.photoThumbnailData.indices.map { Self.thumbnailFilename(index: $0) },
            lastReprintedAt: nil,
            reprintCount: 0,
            passport: payload.committedSession.passport,
            eventRunID: payload.eventRunID,
            eventDesignID: payload.eventDesignID,
            receiptPrintOptions: payload.committedSession.printOptions
        )
    }

    private func ensureArchiveDirectory() throws {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try applyStorageAttributes(to: directoryURL)
    }

    private func cleanupStagingDirectories() throws {
        guard fileManager.fileExists(atPath: directoryURL.path) else { return }
        for directory in try fileManager.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: [.isDirectoryKey]) {
            guard directory.lastPathComponent.hasPrefix("staging-"),
                  (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                continue
            }
            try? fileManager.removeItem(at: directory)
        }
    }

    private func archiveDirectoryURL(for archiveID: String) -> URL {
        directoryURL.appendingPathComponent(archiveID, isDirectory: true)
    }

    private func archiveDirectories() throws -> [URL] {
        guard fileManager.fileExists(atPath: directoryURL.path) else { return [] }
        return try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.creationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ).filter { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                && isValidArchiveID(url.lastPathComponent)
        }
    }

    private func loadMetadata(from directory: URL) throws -> RecentSessionArchiveMetadata {
        do {
            let metadata = try JSONDecoder.archiveDecoder.decode(
                RecentSessionArchiveMetadata.self,
                from: Data(contentsOf: directory.appendingPathComponent(Self.metadataFilename))
            )
            guard metadata.schemaVersion == Self.schemaVersion else {
                throw RecentSessionArchiveError.corruptedArchive("Unsupported archive schema version.")
            }
            return metadata
        } catch {
            throw RecentSessionArchiveError.corruptedArchive(error.localizedDescription)
        }
    }

    private func validateArchive(at directory: URL) throws {
        let metadata = try loadMetadata(from: directory)
        guard fileManager.fileExists(atPath: directory.appendingPathComponent(Self.receiptPreviewFilename).path),
              fileManager.fileExists(atPath: directory.appendingPathComponent(Self.thermalPreviewFilename).path),
              fileManager.fileExists(atPath: directory.appendingPathComponent(Self.rasterDataFilename).path),
              fileManager.fileExists(atPath: directory.appendingPathComponent(Self.rasterCommandFilename).path) else {
            throw RecentSessionArchiveError.corruptedArchive("Required archive files are missing.")
        }
        guard metadata.thumbnailFilenames.allSatisfy({ fileManager.fileExists(atPath: directory.appendingPathComponent($0).path) }) else {
            throw RecentSessionArchiveError.corruptedArchive("One or more photo thumbnails are missing.")
        }
    }

    private func validateRaster(_ rasterizedImage: ThermalRasterizedImage) throws {
        try ThermalImageRasterizer.validateRasterCommand(
            rasterizedImage.rasterCommand,
            imageWidth: rasterizedImage.width,
            imageHeight: rasterizedImage.height,
            bytesPerRow: rasterizedImage.widthBytes,
            rasterDataCount: rasterizedImage.rasterData.count
        )
        try RasterCommandSanitizer.validateOutboundJob(
            heading: ThermalImageRasterizer.receiptPrintHeading(),
            rasterCommand: rasterizedImage.rasterCommand,
            finishing: ThermalImageRasterizer.photoTestFinishing(),
            rasterDataRange: 8..<rasterizedImage.rasterCommand.count
        )
    }

    private func storedArchive(at directory: URL, matches metadata: RecentSessionArchiveMetadata, payload: RecentSessionArchivePayload) throws -> Bool {
        let storedMetadata = try loadMetadata(from: directory)
        guard storedMetadata.archiveID == metadata.archiveID,
              storedMetadata.sessionIdentifier == metadata.sessionIdentifier,
              storedMetadata.createdAt == metadata.createdAt,
              storedMetadata.galleryToken == metadata.galleryToken,
              storedMetadata.galleryURL == metadata.galleryURL,
              storedMetadata.format == metadata.format,
              storedMetadata.passport == metadata.passport,
              storedMetadata.rasterFingerprint == metadata.rasterFingerprint,
              storedMetadata.receiptWidth == metadata.receiptWidth,
              storedMetadata.receiptHeight == metadata.receiptHeight else {
            return false
        }

        let storedRasterCommand = try Data(contentsOf: directory.appendingPathComponent(Self.rasterCommandFilename))
        let storedRasterData = try Data(contentsOf: directory.appendingPathComponent(Self.rasterDataFilename))
        return storedRasterCommand == payload.rasterizedImage.rasterCommand
            && storedRasterData == payload.rasterizedImage.rasterData
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

    private func isValidArchiveID(_ value: String) -> Bool {
        GalleryTokenGenerator.isValidGalleryToken(value) || UUID(uuidString: value) != nil
    }

    private func isSafeFilename(_ value: String) -> Bool {
        !value.isEmpty && !value.contains("/") && !value.contains("..")
    }

    private static func thumbnailFilename(index: Int) -> String {
        "photo-thumb-\(String(format: "%02d", index + 1)).jpg"
    }

    private static let metadataFilename = "metadata.json"
    private static let receiptPreviewFilename = "receipt-preview.png"
    private static let thermalPreviewFilename = "thermal-preview.png"
    private static let rasterDataFilename = "raster.bin"
    private static let rasterCommandFilename = "raster-command.bin"
}

nonisolated private struct RecentSessionArchiveMetadata: Codable, Equatable {
    let schemaVersion: Int
    let archiveID: String
    let sessionIdentifier: String
    let createdAt: Date
    let galleryToken: String
    let galleryURL: URL
    let format: BoothFormat
    let eventProfile: EventProfile?
    let eventName: String?
    let eventLocation: String?
    let photoCount: Int
    let receiptWidth: Int
    let receiptHeight: Int
    let estimatedLengthMillimeters: Double
    let rasterWidthBytes: Int
    let rasterDataByteCount: Int
    let rasterCommandByteCount: Int
    let rasterFingerprint: String
    let yL: UInt8
    let yH: UInt8
    let sanitizationReport: RasterSanitizationReport
    var thumbnailFilenames: [String]
    var lastReprintedAt: Date?
    var reprintCount: Int
    var passport: PassportSessionData? = nil
    var eventRunID: String? = nil
    var eventDesignID: String? = nil
    var receiptPrintOptions: ReceiptPrintOptions? = nil
}

private extension JSONEncoder {
    nonisolated static var archiveEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    nonisolated static var archiveDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private extension String {
    nonisolated var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
