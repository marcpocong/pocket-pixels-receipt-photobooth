//
//  EventHeaderAssetStore.swift
//  PocketPixelsBooth
//

import Foundation
import UIKit

enum EventHeaderAssetStoreError: Error, LocalizedError {
    case unsupportedOrCorruptImage
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .unsupportedOrCorruptImage: "That file is not a readable PNG, JPEG or PDF."
        case .encodingFailed: "The artwork could not be saved."
        }
    }
}

/// Immutable-by-identifier storage. Replacing artwork creates a new file so frozen sessions
/// can continue resolving the exact bytes they started with.
///
/// Bitmaps are normalized once and stored as `<id>.png` (alpha preserved). Single-page PDFs are
/// stored unmodified as `<id>.pdf` so they can be rendered at receipt resolution every time.
nonisolated struct EventHeaderAssetStore: Sendable {
    /// Decoded artwork keyed by directory + identifier. Safe because identifiers never change content.
    nonisolated(unsafe) private static let artworkCache: NSCache<NSString, EventArtwork> = {
        let cache = NSCache<NSString, EventArtwork>()
        cache.countLimit = 8
        return cache
    }()

    nonisolated(unsafe) private let fileManager: FileManager
    private let directoryURL: URL

    init(fileManager: FileManager = .default, directoryURL: URL? = nil) throws {
        self.fileManager = fileManager
        if let directoryURL {
            self.directoryURL = directoryURL
        } else {
            let support = try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            self.directoryURL = support.appendingPathComponent("EventHeaderAssetsV1", isDirectory: true)
        }
        try ensureDirectory()
    }

    /// Imports PNG, JPEG or single-page PDF artwork and returns its new immutable identifier.
    func importArtworkData(_ data: Data) throws -> String {
        guard data.count <= EventArtwork.maximumFileSize else { throw EventArtworkError.fileTooLarge }
        guard EventArtwork.isPDF(data) else { return try importImageData(data) }
        _ = try EventArtwork.makeVector(pdfData: data)
        try ensureDirectory()
        let identifier = UUID().uuidString.lowercased()
        try data.write(to: url(for: identifier, fileExtension: "pdf"), options: .atomic)
        return identifier
    }

    func importImageData(_ data: Data) throws -> String {
        guard let source = UIImage(data: data), source.size.width > 0, source.size.height > 0 else {
            throw EventHeaderAssetStoreError.unsupportedOrCorruptImage
        }
        let normalized = EventHeaderImageProcessor.normalizedSourceImage(source)
        guard let png = normalized.pngData() else { throw EventHeaderAssetStoreError.encodingFailed }
        try ensureDirectory()
        let identifier = UUID().uuidString.lowercased()
        try png.write(to: url(for: identifier, fileExtension: "png"), options: .atomic)
        return identifier
    }

    /// Loads bitmap or vector artwork. Returns nil for unknown, missing or unreadable assets so
    /// callers fall back to the Pocket Pixels header.
    func loadArtwork(identifier: String?) -> EventArtwork? {
        guard let identifier, Self.isValid(identifier) else { return nil }
        let key = "\(directoryURL.path)/\(identifier)" as NSString
        if let cached = Self.artworkCache.object(forKey: key) { return cached }

        let artwork: EventArtwork?
        if let data = try? Data(contentsOf: url(for: identifier, fileExtension: "png")) {
            artwork = UIImage(data: data).map(EventArtwork.init(image:))
        } else if let data = try? Data(contentsOf: url(for: identifier, fileExtension: "pdf")) {
            artwork = try? EventArtwork.makeVector(pdfData: data)
        } else {
            artwork = nil
        }
        if let artwork { Self.artworkCache.setObject(artwork, forKey: key) }
        return artwork
    }

    /// Bitmap view of the artwork (vectors are rendered for display). Prefer `loadArtwork`.
    func loadImage(identifier: String?) -> UIImage? {
        loadArtwork(identifier: identifier)?.image()
    }

    func contains(identifier: String?) -> Bool {
        guard let identifier, Self.isValid(identifier) else { return false }
        return ["png", "pdf"].contains { fileManager.fileExists(atPath: url(for: identifier, fileExtension: $0).path) }
    }

    private func url(for identifier: String, fileExtension: String) -> URL {
        directoryURL.appendingPathComponent(identifier).appendingPathExtension(fileExtension)
    }

    private func ensureDirectory() throws {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        var url = directoryURL
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
#if os(iOS)
        try? fileManager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: directoryURL.path)
#endif
    }

    private static func isValid(_ identifier: String) -> Bool {
        UUID(uuidString: identifier) != nil
    }
}
