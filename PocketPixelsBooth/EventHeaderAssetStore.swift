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
        case .unsupportedOrCorruptImage: "That file is not a readable PNG or JPEG image."
        case .encodingFailed: "The header image could not be saved."
        }
    }
}

/// Immutable-by-identifier storage. Replacing an image creates a new file so frozen sessions
/// can continue resolving the exact bytes they started with.
nonisolated struct EventHeaderAssetStore: Sendable {
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

    func importImageData(_ data: Data) throws -> String {
        guard let source = UIImage(data: data), source.size.width > 0, source.size.height > 0 else {
            throw EventHeaderAssetStoreError.unsupportedOrCorruptImage
        }
        let normalized = EventHeaderImageProcessor.normalizedSourceImage(source)
        guard let png = normalized.pngData() else { throw EventHeaderAssetStoreError.encodingFailed }
        try ensureDirectory()
        let identifier = UUID().uuidString.lowercased()
        try png.write(to: url(for: identifier), options: .atomic)
        return identifier
    }

    func loadImage(identifier: String?) -> UIImage? {
        guard let identifier, Self.isValid(identifier),
              let data = try? Data(contentsOf: url(for: identifier)) else { return nil }
        return UIImage(data: data)
    }

    func contains(identifier: String?) -> Bool {
        guard let identifier, Self.isValid(identifier) else { return false }
        return fileManager.fileExists(atPath: url(for: identifier).path)
    }

    private func url(for identifier: String) -> URL {
        directoryURL.appendingPathComponent(identifier).appendingPathExtension("png")
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
