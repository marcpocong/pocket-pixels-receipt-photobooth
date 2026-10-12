//
//  StickerCatalogStore.swift
//  PocketPixelsBooth
//
//  Operator-approved sticker imports kept in Application Support. Image bytes live in files
//  (never UserDefaults); a small versioned manifest records names, categories, order and the
//  Event collection. Every file is validated by the bounded decoder on import and again on
//  load, so a corrupt or deleted file is skipped instead of reaching a guest.
//

import CoreGraphics
import Foundation
import UIKit

nonisolated struct CustomStickerRecord: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var category: StickerCategory
    var isEnabled: Bool
    var isInEventCollection: Bool
    var sortOrder: Int
    let fileName: String
    let typeIdentifier: String
    let byteCount: Int
    let pixelWidth: Int
    let pixelHeight: Int
    let frameCount: Int
    let importedAt: Date
    var printWarning: String?

    var assetID: String { "custom.\(id.uuidString.lowercased())" }
    var aspectRatio: CGFloat { pixelHeight > 0 ? CGFloat(pixelWidth) / CGFloat(pixelHeight) : 1 }

    var asset: StickerAsset {
        StickerAsset(
            id: assetID,
            name: name,
            tags: [category.displayName, isInEventCollection ? "event" : ""].filter { !$0.isEmpty },
            category: category,
            provenance: .operatorImport,
            isAnimated: frameCount > 1,
            frameCount: frameCount,
            aspectRatio: aspectRatio,
            isInEventCollection: isInEventCollection,
            printWarning: printWarning
        )
    }
}

nonisolated struct StickerCatalogManifest: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1
    var schemaVersion = currentSchemaVersion
    var records: [CustomStickerRecord] = []
}

nonisolated enum StickerCatalogError: Error, LocalizedError, Equatable {
    case image(StickerImageError)
    case notFound
    case storage(String)
    case libraryFull

    var errorDescription: String? {
        switch self {
        case .image(let error): error.localizedDescription
        case .notFound: "That sticker no longer exists."
        case .storage(let message): "The sticker library could not be saved: \(message)"
        case .libraryFull: "The sticker library is full (\(StickerCatalogStore.maximumRecords) stickers). Delete some first."
        }
    }
}

nonisolated struct StickerCatalogStore: Sendable {
    static let maximumRecords = 200
    static let didChangeNotification = Notification.Name("madeToKeep.stickerCatalog.didChange")

    nonisolated(unsafe) private let fileManager: FileManager
    let directoryURL: URL

    private var manifestURL: URL { directoryURL.appendingPathComponent("manifest.json") }
    private var assetsURL: URL { directoryURL.appendingPathComponent("assets", isDirectory: true) }

    init(fileManager: FileManager = .default, directoryURL: URL? = nil) throws {
        self.fileManager = fileManager
        if let directoryURL {
            self.directoryURL = directoryURL
        } else {
            let support = try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            self.directoryURL = support.appendingPathComponent("StickerStudioV1", isDirectory: true)
        }
        try ensureDirectories()
    }

    // MARK: Manifest

    /// Missing or corrupt manifests read as an empty library; asset files are left untouched
    /// so an operator can re-import without data loss.
    func loadManifest() -> StickerCatalogManifest {
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(StickerCatalogManifest.self, from: data) else {
            return StickerCatalogManifest()
        }
        return manifest
    }

    func saveManifest(_ manifest: StickerCatalogManifest) throws {
        var normalized = manifest
        normalized.schemaVersion = StickerCatalogManifest.currentSchemaVersion
        normalized.records = normalized.records
            .sorted { ($0.sortOrder, $0.importedAt) < ($1.sortOrder, $1.importedAt) }
            .enumerated()
            .map { index, record in
                var copy = record
                copy.sortOrder = index
                copy.name = Self.normalizedName(record.name)
                return copy
            }
        do {
            let data = try JSONEncoder().encode(normalized)
            try DurableFileWriter.write(data, to: manifestURL, fileManager: fileManager)
        } catch {
            throw StickerCatalogError.storage(error.localizedDescription)
        }
    }

    /// Records whose files still exist, in operator order.
    func records() -> [CustomStickerRecord] {
        loadManifest().records
            .filter { fileManager.fileExists(atPath: fileURL(for: $0).path) }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    // MARK: Import

    /// Copies a security-scoped file into the library, releasing access when done.
    func importFile(at url: URL, category: StickerCategory) throws -> CustomStickerRecord {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values?.isRegularFile != false else { throw StickerCatalogError.image(.unsupportedType) }
        if let size = values?.fileSize, size > StickerImageLimits.maximumImportBytes {
            throw StickerCatalogError.image(.tooLarge)
        }
        let data: Data
        do {
            data = try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            throw StickerCatalogError.image(.decodeFailed)
        }
        let name = url.deletingPathExtension().lastPathComponent
        return try importData(data, name: name, category: category)
    }

    func importData(_ data: Data, name: String, category: StickerCategory, now: Date = Date()) throws -> CustomStickerRecord {
        let info: StickerImageInfo
        let preview: CGImage
        do {
            info = try StickerImageDecoder.inspect(data)
            preview = try StickerImageDecoder.decodeFrame(data, frameIndex: info.frameCount > 1 ? info.frameCount / 2 : 0, maximumPixelDimension: StickerImageLimits.thumbnailPixelDimension)
        } catch let error as StickerImageError {
            throw StickerCatalogError.image(error)
        }
        var manifest = loadManifest()
        guard manifest.records.count < Self.maximumRecords else { throw StickerCatalogError.libraryFull }
        let id = UUID()
        let fileName = "\(id.uuidString.lowercased()).\(info.fileExtension)"
        let record = CustomStickerRecord(
            id: id,
            name: Self.normalizedName(name),
            category: StickerCategory.assignableToImports.contains(category) ? category : .classic,
            isEnabled: true,
            isInEventCollection: category == .event,
            sortOrder: (manifest.records.map(\.sortOrder).max() ?? -1) + 1,
            fileName: fileName,
            typeIdentifier: info.typeIdentifier,
            byteCount: data.count,
            pixelWidth: info.pixelWidth,
            pixelHeight: info.pixelHeight,
            frameCount: info.frameCount,
            importedAt: now,
            printWarning: StickerPrintPreparation.contrastSpread(of: preview) < StickerPrintPreparation.lowContrastThreshold
                ? StickerPrintPreparation.lowContrastWarning
                : nil
        )
        do {
            try ensureDirectories()
            try DurableFileWriter.write(data, to: assetsURL.appendingPathComponent(fileName), fileManager: fileManager)
        } catch {
            throw StickerCatalogError.storage(error.localizedDescription)
        }
        manifest.records.append(record)
        do {
            try saveManifest(manifest)
        } catch {
            try? fileManager.removeItem(at: assetsURL.appendingPathComponent(fileName))
            throw error
        }
        return record
    }

    // MARK: Editing

    func update(_ id: UUID, _ change: (inout CustomStickerRecord) -> Void) throws {
        var manifest = loadManifest()
        guard let index = manifest.records.firstIndex(where: { $0.id == id }) else { throw StickerCatalogError.notFound }
        change(&manifest.records[index])
        try saveManifest(manifest)
    }

    func delete(_ id: UUID) throws {
        var manifest = loadManifest()
        guard let index = manifest.records.firstIndex(where: { $0.id == id }) else { throw StickerCatalogError.notFound }
        let record = manifest.records.remove(at: index)
        try saveManifest(manifest)
        try? fileManager.removeItem(at: fileURL(for: record))
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) throws {
        var manifest = loadManifest()
        let ordered = manifest.records.sorted { $0.sortOrder < $1.sortOrder }
        let moving = source.filter { ordered.indices.contains($0) }.map { ordered[$0] }
        var remaining = ordered.enumerated().filter { !source.contains($0.offset) }.map(\.element)
        let insertion = min(max(0, destination - source.filter { $0 < destination }.count), remaining.count)
        remaining.insert(contentsOf: moving, at: insertion)
        let ordered2 = remaining
        manifest.records = ordered2.enumerated().map { index, record in
            var copy = record
            copy.sortOrder = index
            return copy
        }
        try saveManifest(manifest)
    }

    // MARK: Loading

    func fileURL(for record: CustomStickerRecord) -> URL {
        assetsURL.appendingPathComponent(record.fileName)
    }

    func data(for record: CustomStickerRecord) -> Data? {
        // File names are generated by this store; reject anything that could escape the folder.
        guard !record.fileName.contains("/"), !record.fileName.hasPrefix(".") else { return nil }
        return try? Data(contentsOf: fileURL(for: record), options: [.mappedIfSafe])
    }

    func image(for record: CustomStickerRecord, frameIndex: Int, maximumPixelDimension: Int) -> CGImage? {
        guard let data = data(for: record) else { return nil }
        return try? StickerImageDecoder.decodeFrame(data, frameIndex: frameIndex, maximumPixelDimension: maximumPixelDimension)
    }

    /// Total bytes of imported files that still exist.
    func storageBytes() -> Int {
        records().reduce(0) { $0 + $1.byteCount }
    }

    private static func normalizedName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Sticker" : String(trimmed.prefix(40))
    }

    private func ensureDirectories() throws {
        try fileManager.createDirectory(at: assetsURL, withIntermediateDirectories: true)
        var url = directoryURL
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }
}

// MARK: - Guest catalog

/// The stickers one guest session may browse, built from frozen settings. Built-in artwork and
/// the operator collection are available offline; online results are layered on separately.
nonisolated struct StickerGuestCatalog: Sendable {
    let assets: [StickerAsset]
    let customRecords: [String: CustomStickerRecord]

    static let empty = StickerGuestCatalog(assets: [], customRecords: [:])

    static func make(settings: StickerStudioSettings, store: StickerCatalogStore?) -> StickerGuestCatalog {
        guard settings.isEnabled else { return .empty }
        var assets: [StickerAsset] = []
        var custom: [String: CustomStickerRecord] = [:]
        if settings.builtInStickersEnabled {
            assets += BundledStickerFactory.assets
        }
        if settings.operatorCollectionEnabled, let store {
            for record in store.records() where record.isEnabled {
                custom[record.assetID] = record
                var asset = record.asset
                // Event-tagged stickers show in Event; their own category keeps them findable too.
                if record.isInEventCollection { asset.category = .event }
                assets.append(asset)
            }
        }
        let visible = assets.filter { !settings.hiddenCategories.contains($0.category) }
        return StickerGuestCatalog(assets: visible, customRecords: custom)
    }

    /// Non-empty categories in display order. Never shows an empty tab.
    var categories: [StickerCategory] {
        StickerCategory.allCases.filter { category in category != .online && assets.contains { $0.category == category } }
    }

    func assets(in category: StickerCategory) -> [StickerAsset] {
        assets.filter { $0.category == category }
    }

    func search(_ query: String) -> [StickerAsset] {
        assets.filter { $0.matches(query) }
    }

    func asset(id: String) -> StickerAsset? {
        assets.first { $0.id == id }
    }

    /// Decodes artwork for a local asset. nil means invalid / missing (never a crash).
    func image(for asset: StickerAsset, frameIndex: Int, maximumPixelDimension: Int, store: StickerCatalogStore?) -> CGImage? {
        switch asset.provenance.source {
        case .builtIn:
            return BundledStickerFactory.image(for: asset.id)
        case .operatorImport:
            guard let record = customRecords[asset.id], let store else { return nil }
            return store.image(for: record, frameIndex: frameIndex, maximumPixelDimension: maximumPixelDimension)
        case .online:
            return nil
        }
    }
}
