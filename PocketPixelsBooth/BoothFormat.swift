//
//  BoothFormat.swift
//  PocketPixelsBooth
//

import Foundation
import UIKit

enum BoothFormat: String, Codable, CaseIterable, Identifiable, Sendable {
    case solo
    case duo
    case grid
    case strip
    case gridSix
    case passport

    nonisolated var id: String { rawValue }

    nonisolated var displayName: String {
        switch self {
        case .solo:
            "Solo"
        case .duo:
            "Duo"
        case .grid:
            "Grid"
        case .gridSix:
            "Grid 6"
        case .strip:
            "Strip"
        case .passport:
            // Customer-facing name only; the stored raw value stays "passport".
            "Photo Pass"
        }
    }

    nonisolated var shortDescription: String {
        switch self {
        case .solo:
            "One large portrait"
        case .duo:
            "Two stacked portraits"
        case .grid:
            "Classic four-photo grid"
        case .gridSix:
            "Six-photo grid"
        case .strip:
            "Three-photo classic strip"
        case .passport:
            "Two-photo event keepsake"
        }
    }

    nonisolated var photoCount: Int {
        switch self {
        case .solo:
            1
        case .duo:
            2
        case .grid:
            4
        case .gridSix:
            6
        case .strip:
            3
        case .passport:
            2
        }
    }

    nonisolated var photoCountLabel: String {
        photoCount == 1 ? "1 photo" : "\(photoCount) photos"
    }

    /// Photo Pass (stored as Passport) adds keepsake details, a signature and a dedicated preview after photo review.
    nonisolated var usesPassportFlow: Bool {
        self == .passport
    }

    nonisolated var reviewSummary: String {
        "\(displayName.uppercased()) · \(photoCountLabel.uppercased())"
    }
}

/// The guest-facing composition for one capture. This is shared by the live aperture,
/// transient confirmation, and review so each stage uses the same geometric crop.
enum CapturePhotoPresentation: Sendable, Equatable {
    case portrait
    case landscape

    nonisolated static func resolve(format: BoothFormat, photoIndex: Int) -> Self {
        switch format {
        case .duo, .strip:
            .landscape
        case .passport:
            PassportPhotoRole(photoIndex: photoIndex) == .hero ? .landscape : .portrait
        case .solo, .grid, .gridSix:
            .portrait
        }
    }

    nonisolated var aspectRatio: CGFloat {
        switch self {
        case .portrait:
            3.0 / 4.0
        case .landscape:
            ReceiptComposer.landscapePresentationAspectRatio
        }
    }

    /// Creates a color, presentation-only image. The stored source is never replaced by this crop.
    nonisolated func confirmationPhoto(
        from image: UIImage,
        format: BoothFormat,
        photoIndex: Int,
        maximumDimension: CGFloat = 1_200
    ) -> UIImage {
        let cropped: UIImage
        if format == .passport, let role = PassportPhotoRole(photoIndex: photoIndex) {
            cropped = PassportPhotoProcessor.presentationPhoto(from: image, role: role)
        } else {
            switch self {
            case .portrait:
                cropped = BoothPhotoProcessor.normalizedPortraitPhoto(from: image)
            case .landscape:
                cropped = ReceiptComposer.makeLandscapePresentationPhoto(from: image)
            }
        }

        let pixelSize = ThermalPhotoProcessor.pixelSize(of: cropped)
        let scale = min(1, maximumDimension / max(1, max(pixelSize.width, pixelSize.height)))
        guard scale < 1 else { return cropped }

        let targetSize = CGSize(
            width: max(1, floor(pixelSize.width * scale)),
            height: max(1, floor(pixelSize.height * scale))
        )
        let rendererFormat = UIGraphicsImageRendererFormat()
        rendererFormat.scale = 1
        rendererFormat.opaque = true
        return UIGraphicsImageRenderer(size: targetSize, format: rendererFormat).image { context in
            context.cgContext.interpolationQuality = .high
            cropped.draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }
}
