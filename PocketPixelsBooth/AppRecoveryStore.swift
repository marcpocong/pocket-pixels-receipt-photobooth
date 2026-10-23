//
//  AppRecoveryStore.swift
//  PocketPixelsBooth
//

import OSLog
import Foundation
import UIKit

nonisolated enum AppRecoveryStage: String, Codable, Sendable {
    case formatSelected
    case photosCaptured
    case receiptComposed
    case printStatusUnknown
}

nonisolated struct AppRecoverySnapshot: Codable, Sendable {
    nonisolated static let schemaVersion = 1

    let schemaVersion: Int
    let sessionIdentifier: String
    let createdAt: Date
    let format: BoothFormat
    let eventProfile: EventProfile?
    let galleryToken: String?
    let galleryURL: URL?
    let photoJPEGData: [Data]
    let receiptPreviewPNGData: Data?
    let thermalPreviewPNGData: Data?
    let rasterFingerprint: String?
    let stage: AppRecoveryStage
    let updatedAt: Date
    /// Committed Passport keepsake data, retained only for the session that owns this snapshot.
    var passport: PassportSessionData? = nil
    var receiptPrintOptions: ReceiptPrintOptions? = nil
    var galleryReceiptStyle: GalleryReceiptStyle? = nil
}

nonisolated enum AppRecoveryStoreError: Error, LocalizedError, Equatable {
    case unavailable
    case encodingFailed(String)
    case writeFailed(String)
    case verificationFailed

    var errorDescription: String? {
        switch self {
        case .unavailable: "Recovery storage is unavailable."
        case .encodingFailed(let detail): "Recovery state could not be encoded: \(detail)"
        case .writeFailed(let detail): "Recovery state could not be written: \(detail)"
        case .verificationFailed: "Recovery state did not read back correctly after writing."
        }
    }
}

nonisolated struct AppRecoveryStore: Sendable {
    nonisolated(unsafe) private let fileManager: FileManager
    private let directoryURL: URL
    private let fileURL: URL

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
            self.directoryURL = supportURL.appendingPathComponent("AppRecoveryStateV1", isDirectory: true)
        }
        self.fileURL = self.directoryURL.appendingPathComponent("last-session.json")
        try ensureDirectory()
    }

    nonisolated var storagePath: String {
        fileURL.path
    }

    /// Durability-critical save. Returns only after the snapshot is flushed to stable storage and
    /// read back byte-for-byte; throws otherwise. The pre-print `printStatusUnknown` checkpoint
    /// must use this so a failed write blocks printing (fail-closed).
    nonisolated func saveCritical(_ snapshot: AppRecoverySnapshot) throws {
        let data: Data
        do {
            data = try JSONEncoder.recoveryEncoder.encode(snapshot)
        } catch {
            throw AppRecoveryStoreError.encodingFailed(error.localizedDescription)
        }
        do {
            try ensureDirectory()
            try DurableFileWriter.write(data, to: fileURL, fileManager: fileManager)
        } catch {
            throw AppRecoveryStoreError.writeFailed(error.localizedDescription)
        }
        // Storage attributes (backup exclusion, data protection) do not affect durability.
        applyStorageAttributes(to: fileURL)
        guard let stored = try? Data(contentsOf: fileURL), stored == data else {
            throw AppRecoveryStoreError.verificationFailed
        }
    }

    /// Best-effort save for non-critical progress checkpoints (format chosen, photos captured,
    /// receipt composed). Failures are logged; they never block the customer flow.
    nonisolated func save(_ snapshot: AppRecoverySnapshot) {
        do {
            try saveCritical(snapshot)
        } catch {
            BoothDiagnostics.recovery.error("Non-critical recovery save failed stage=\(snapshot.stage.rawValue, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }
    }

    nonisolated func load() -> AppRecoverySnapshot? {
        guard fileManager.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let snapshot = try? JSONDecoder.recoveryDecoder.decode(AppRecoverySnapshot.self, from: data),
              snapshot.schemaVersion == AppRecoverySnapshot.schemaVersion else {
            return nil
        }

        return snapshot
    }

    /// Keep the exact checkpoint/photos before an operator closes an interrupted session.
    /// Retention is additive; the active checkpoint and every existing archive stay untouched.
    nonisolated func retainForReference(_ snapshot: AppRecoverySnapshot) throws {
        let destination = directoryURL.appendingPathComponent("RetainedSessions", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try AppRecoveryStore(directoryURL: destination).saveCritical(snapshot)
    }

    nonisolated func retainedSessions() throws -> [AppRecoverySnapshot] {
        let root = directoryURL.appendingPathComponent("RetainedSessions", isDirectory: true)
        guard fileManager.fileExists(atPath: root.path) else { return [] }
        return try fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).map {
            let data = try Data(contentsOf: $0.appendingPathComponent("last-session.json"))
            return try JSONDecoder.recoveryDecoder.decode(AppRecoverySnapshot.self, from: data)
        }.sorted { $0.updatedAt > $1.updatedAt }
    }

    nonisolated func clear(sessionIdentifier: String? = nil) {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return
        }

        if let sessionIdentifier,
           let existing = load(),
           existing.sessionIdentifier != sessionIdentifier {
            return
        }

        try? fileManager.removeItem(at: fileURL)
    }

    nonisolated static func photoData(from image: UIImage) -> Data? {
        autoreleasepool {
            image.normalizedForGalleryUpload()
                .resizedForGalleryUpload(maxLongestSide: 1_600)
                .jpegData(compressionQuality: 0.82)
        }
    }

    private func ensureDirectory() throws {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        applyStorageAttributes(to: directoryURL)
    }

    private func applyStorageAttributes(to url: URL) {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try? mutableURL.setResourceValues(values)
#if os(iOS)
        try? fileManager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
#endif
    }
}

private extension JSONEncoder {
    nonisolated static var recoveryEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    nonisolated static var recoveryDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// An acknowledgement belongs to one exact checkpoint. Relaunch cannot turn an already
/// reviewed receipt into a new urgent issue, and a later print can never inherit the approval.
nonisolated enum OperatorRecoveryAcknowledgement {
    static let key = "pocketPixels.venueOwnerAcknowledgedPrintIdentity"
    static func identity(_ snapshot: AppRecoverySnapshot) -> String {
        "\(snapshot.sessionIdentifier)|\(snapshot.updatedAt.timeIntervalSince1970)"
    }
    static func retainAndAcknowledge(_ snapshot: AppRecoverySnapshot, store: AppRecoveryStore,
                                     defaults: UserDefaults = .standard) throws -> String {
        try store.retainForReference(snapshot)
        let identity = identity(snapshot)
        defaults.set(identity, forKey: key)
        return identity
    }
}
