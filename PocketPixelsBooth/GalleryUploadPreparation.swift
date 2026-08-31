//
//  GalleryUploadPreparation.swift
//  PocketPixelsBooth
//

import Foundation
import UIKit

struct GalleryUploadTimingMetrics: Codable, Equatable, Sendable {
    let imagePreparationDuration: TimeInterval
    let jsonEncodingDuration: TimeInterval
    let uploadNetworkDuration: TimeInterval?
    let totalDuration: TimeInterval?
    let decodedPayloadByteCount: Int
    let jsonBodyByteCount: Int?

    static let empty = GalleryUploadTimingMetrics(
        imagePreparationDuration: 0,
        jsonEncodingDuration: 0,
        uploadNetworkDuration: nil,
        totalDuration: nil,
        decodedPayloadByteCount: 0,
        jsonBodyByteCount: nil
    )
}

enum GalleryUploadPreparation {
    nonisolated static let photoMaxLongestSide = 1_600
    nonisolated static let photoTargetMaxBytes = 500 * 1024
    nonisolated static let receiptTargetMaxBytes = 350 * 1024

    nonisolated static func preparedPhotoData(from image: UIImage) throws -> Data {
        try autoreleasepool {
            let normalized = image.normalizedForGalleryUpload()
            let resized = normalized.resizedForGalleryUpload(maxLongestSide: photoMaxLongestSide)
            return try encodeAdaptiveJPEG(
                resized,
                startingQuality: 0.78,
                minimumQuality: 0.62,
                targetMaxBytes: photoTargetMaxBytes,
                minimumLongestSide: 1_200
            )
        }
    }

    nonisolated static func preparedReceiptData(from image: UIImage) throws -> Data {
        try autoreleasepool {
            let receipt = image.normalizedForGalleryUpload().resizedForGalleryUpload(width: BoothConfiguration.receiptWidth)
            return try encodeAdaptiveJPEG(
                receipt,
                startingQuality: 0.92,
                minimumQuality: 0.78,
                targetMaxBytes: receiptTargetMaxBytes,
                minimumLongestSide: CGFloat(BoothConfiguration.receiptWidth)
            )
        }
    }

    nonisolated private static func encodeAdaptiveJPEG(
        _ image: UIImage,
        startingQuality: CGFloat,
        minimumQuality: CGFloat,
        targetMaxBytes: Int,
        minimumLongestSide: CGFloat
    ) throws -> Data {
        var workingImage = image
        var quality = startingQuality
        var bestData = try encodeJPEGData(workingImage, quality: quality)

        while bestData.count > targetMaxBytes && quality > minimumQuality + 0.001 {
            quality = max(minimumQuality, quality - 0.06)
            bestData = try encodeJPEGData(workingImage, quality: quality)
        }

        var longestSide = max(workingImage.size.width, workingImage.size.height)
        while bestData.count > targetMaxBytes && longestSide > minimumLongestSide + 1 {
            longestSide = max(minimumLongestSide, floor(longestSide * 0.88))
            workingImage = workingImage.resizedForGalleryUpload(maxLongestSide: Int(longestSide))
            bestData = try encodeJPEGData(workingImage, quality: minimumQuality)
        }

        return bestData
    }

    nonisolated private static func encodeJPEGData(_ image: UIImage, quality: CGFloat) throws -> Data {
        guard let data = image.jpegData(compressionQuality: quality) else {
            throw GalleryUploadError.imageEncoding("JPEG data could not be created.")
        }

        guard data.count <= GalleryPreparedUploadMetrics.maxFileDecodedBytes else {
            throw GalleryUploadError.imageEncoding("Encoded JPEG is larger than 6 MB.")
        }

        return data
    }
}

extension UIImage {
    nonisolated func normalizedForGalleryUpload() -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            draw(in: CGRect(origin: .zero, size: size))
        }
    }

    nonisolated func resizedForGalleryUpload(maxLongestSide: Int) -> UIImage {
        guard maxLongestSide > 0 else { return self }
        let longest = max(size.width, size.height)
        guard longest > CGFloat(maxLongestSide) else { return self }
        let scale = CGFloat(maxLongestSide) / longest
        return resizedForGalleryUpload(size: CGSize(width: floor(size.width * scale), height: floor(size.height * scale)))
    }

    nonisolated func resizedForGalleryUpload(width targetWidth: Int) -> UIImage {
        guard targetWidth > 0, size.width > 0 else { return self }
        let scale = CGFloat(targetWidth) / size.width
        return resizedForGalleryUpload(size: CGSize(width: CGFloat(targetWidth), height: floor(size.height * scale)))
    }

    nonisolated private func resizedForGalleryUpload(size targetSize: CGSize) -> UIImage {
        let safeSize = CGSize(width: max(1, targetSize.width), height: max(1, targetSize.height))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: safeSize, format: format)
        return renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: safeSize))
            draw(in: CGRect(origin: .zero, size: safeSize))
        }
    }
}
