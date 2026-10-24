import Foundation
import ImageIO
import Photos
import UniformTypeIdentifiers
import UIKit
import SwiftUI

extension Notification.Name {
    static let originalPhotoRetentionFailed = Notification.Name("OriginalPhotoRetentionFailed")
}

nonisolated enum MediaExportError: Error, LocalizedError {
    case permission, unavailable, saveFailed
    var errorDescription: String? {
        switch self {
        case .permission: "Could not save; permission required. Allow Add Photos access in iPad Settings."
        case .unavailable: "Could not save; source media or storage unavailable."
        case .saveFailed: "Could not save; Photos storage unavailable or the save was interrupted. Try again."
        }
    }
}

nonisolated protocol PhotosLibraryWriting: Sendable {
    func requestAddAccess() async -> Bool
    func save(files: [URL]) async throws
}

nonisolated struct SystemPhotosLibraryWriter: PhotosLibraryWriting {
    func requestAddAccess() async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        return status == .authorized || status == .limited
    }
    func save(files: [URL]) async throws {
        // Photos copies the immutable encoded files without resizing or regenerating them.
        // Return only after Photos confirms the transaction; sources remain owned by the app.
        try await PHPhotoLibrary.shared().performChanges {
            for file in files {
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions(); options.shouldMoveFile = false
                request.addResource(with: .photo, fileURL: file, options: options)
            }
        }
    }
}

nonisolated struct SessionPhotoSource: Identifiable, Sendable {
    enum Quality: String, Codable, Sendable { case original = "Original capture", prepared = "Prepared gallery photo", thumbnail = "Thumbnail only" }
    let id: Int
    let quality: Quality
    let data: Data
}

/// Files are lazy-loaded only for a selected session. No Photos reads, uploads or printer calls.
nonisolated enum SessionMediaExport {
    static let retentionErrorKey = "pocketPixels.originalPhotoRetentionNeedsReview"
    static let retentionKey = "pocketPixels.keepOriginalPhotosForExport"
    static var keepsOriginals: Bool { UserDefaults.standard.object(forKey: retentionKey) as? Bool ?? true }

    static func save(data: [Data], writer: any PhotosLibraryWriting = SystemPhotosLibraryWriter()) async throws {
        guard !data.isEmpty, data.allSatisfy({ CGImageSourceCreateWithData($0 as CFData, nil) != nil }) else { throw MediaExportError.unavailable }
        guard await writer.requestAddAccess() else { throw MediaExportError.permission }
        try Task.checkCancellation()
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("MediaExport-" + UUID().uuidString, isDirectory: true)
        let files = try await Task.detached(priority: .utility) {
            try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.complete])
            do {
                return try data.enumerated().map { index, bytes in
                    // Uniform type comes from the encoded source, not a newly rendered screenshot.
                    guard let source = CGImageSourceCreateWithData(bytes as CFData, nil), let type = CGImageSourceGetType(source) else { throw MediaExportError.unavailable }
                    let ext = UTType(type as String)?.preferredFilenameExtension ?? "image"
                    let file = temp.appendingPathComponent("photo-\(index).\(ext)")
                    try bytes.write(to: file, options: .atomic)
                    return file
                }
            } catch { try? FileManager.default.removeItem(at: temp); throw error }
        }.value
        defer { try? FileManager.default.removeItem(at: temp) }
        do { try await writer.save(files: files) }
        catch { throw MediaExportError.saveFailed }
    }

    static func photos(archive: RecentSessionArchive, store: RecentSessionArchiveStore,
                       pending: GalleryPendingUploadStore? = nil, recovery: AppRecoveryStore? = nil) throws -> [SessionPhotoSource] {
        let originals = try store.originalPhotos(archiveID: archive.summary.archiveID, sessionID: archive.summary.sessionIdentifier)
        if !originals.isEmpty { return originals }
        if let payload = try pending?.load(galleryToken: archive.galleryToken),
           payload.sessionID == archive.summary.sessionIdentifier, payload.galleryURL == archive.galleryURL,
           payload.photos.count == archive.summary.photoCount {
            return payload.photos.enumerated().map { SessionPhotoSource(id: $0.offset, quality: .prepared, data: $0.element.data) }
        }
        if let recovery {
            let snapshots = ([try recovery.loadChecked()].compactMap { $0 }) + (try recovery.retainedSessions())
            if let match = snapshots.first(where: { $0.sessionIdentifier == archive.summary.sessionIdentifier && $0.galleryToken == archive.galleryToken && $0.galleryURL == archive.galleryURL }) {
                if let captures = match.originalCaptureData, captures.count == archive.summary.photoCount, captures.allSatisfy({ $0 != nil }) {
                    return captures.enumerated().compactMap { index, data in data.map { SessionPhotoSource(id: index, quality: .original, data: $0) } }
                }
                if match.photoJPEGData.count == archive.summary.photoCount {
                    return match.photoJPEGData.enumerated().map { SessionPhotoSource(id: $0.offset, quality: .prepared, data: $0.element) }
                }
            }
        }
        return archive.thumbnailData.enumerated().map { SessionPhotoSource(id: $0.offset, quality: .thumbnail, data: $0.element) }
    }
}

/// Decode only a small preview, away from the main thread. Never used as the export source.
struct ExportPhotoThumbnail: SwiftUI.View {
    let data: Data
    @SwiftUI.State private var image: UIImage?
    var body: some SwiftUI.View {
        SwiftUI.Group {
            if let image { SwiftUI.Image(uiImage: image).resizable().scaledToFit() }
            else { SwiftUI.ProgressView() }
        }.task {
            image = await Task.detached(priority: .utility) {
                guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 320] as CFDictionary) else { return nil as UIImage? }
                return UIImage(cgImage: cg)
            }.value
        }
    }
}


struct SessionPhotoPreview: View {
    let source: SessionPhotoSource
    @State private var image: UIImage?
    var body: some View {
        Group {
            if let image { OperatorZoomableReceiptView(image: image, accessibilityLabel: "Individual photo \(source.id + 1)") }
            else { ProgressView("Loading photo…") }
        }.task(id: source.id) {
            image = await Task.detached(priority: .userInitiated) { UIImage(data: source.data)?.preparingForDisplay() }.value
        }
    }
}
