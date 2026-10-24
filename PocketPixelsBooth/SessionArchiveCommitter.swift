//
//  SessionArchiveCommitter.swift
//  PocketPixelsBooth
//
//  Durability contract for printed customer sessions:
//
//  1. After the receipt is composed, the frozen reprint payload (metadata, raster command,
//     receipt and thermal previews) is committed to RecentSessionArchiveStore with durable,
//     flushed writes. Photo thumbnails follow as a separate, non-critical step.
//  2. No receipt bytes are sent until that commit has succeeded (it is retried once at print
//     time). The pre-print crash-recovery checkpoint is then written fail-closed by PrintSpooler.
//  3. The crash-recovery record is cleared only after a successful print, when the archive is
//     already guaranteed to exist. There is no window in which a completed print has neither an
//     archive nor a useful recovery record.
//

import OSLog
import Foundation
import UIKit

nonisolated enum SessionArchiveCommitter {
    enum CommitError: Error, LocalizedError {
        case missingPayload

        var errorDescription: String? {
            "No reprint record was prepared for this session."
        }
    }

    /// Commits the frozen print payload. Idempotent for the same session and raster.
    nonisolated static func commitPrintPayload(
        _ payload: RecentSessionArchivePayload,
        store: RecentSessionArchiveStore? = nil
    ) throws {
        let store = try store ?? RecentSessionArchiveStore()
        let critical = RecentSessionArchivePayload(
            committedSession: payload.committedSession,
            composedReceipt: payload.composedReceipt,
            receiptPreviewPNGData: payload.receiptPreviewPNGData,
            thermalPreviewPNGData: payload.thermalPreviewPNGData,
            rasterizedImage: payload.rasterizedImage,
            photoThumbnailData: [],
            eventRunID: payload.eventRunID, eventDesignID: payload.eventDesignID
        )
        try store.save(critical)
        BoothDiagnostics.archive.info("Archive print payload committed session=\(payload.committedSession.sessionIdentifier, privacy: .public)")
    }

    /// Best effort: generates and attaches display thumbnails after the payload is durable.
    nonisolated static func attachThumbnails(
        for committedSession: CommittedGallerySession,
        store: RecentSessionArchiveStore? = nil
    ) {
        do {
            let store = try store ?? RecentSessionArchiveStore()
            let thumbnails = try committedSession.photos.map { try thumbnailData(from: $0) }
            try store.attachThumbnails(archiveID: committedSession.galleryToken, thumbnails: thumbnails)
        } catch {
            BoothDiagnostics.archive.error("Archive thumbnails failed (non-critical) session=\(committedSession.sessionIdentifier, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }
    }

    nonisolated static func thumbnailData(from image: UIImage, maxLongestSide: Int = 220) throws -> Data {
        let resized = image.normalizedForGalleryUpload().resizedForGalleryUpload(maxLongestSide: maxLongestSide)
        guard let data = resized.jpegData(compressionQuality: 0.72) else {
            throw GalleryUploadError.imageEncoding("Recent session thumbnail could not be encoded.")
        }
        return data
    }
}
