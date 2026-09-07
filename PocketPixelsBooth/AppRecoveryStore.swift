//
//  AppRecoveryStore.swift
//  PocketPixelsBooth
//

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

    nonisolated func save(_ snapshot: AppRecoverySnapshot) {
        do {
            try ensureDirectory()
            let data = try JSONEncoder.recoveryEncoder.encode(snapshot)
            try data.write(to: fileURL, options: .atomic)
            try applyStorageAttributes(to: fileURL)
        } catch {
#if DEBUG
            print("[AppRecoveryStore] save failed: \(error.localizedDescription)")
#endif
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
        try applyStorageAttributes(to: directoryURL)
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
