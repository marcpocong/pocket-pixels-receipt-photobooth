//
//  PassportPhotoProcessor.swift
//  PocketPixelsBooth
//
//  Passport-only photo handling. Other formats keep BoothPhotoProcessor's 3:4 capture crop.
//  Passport keeps the full orientation-normalized frame and applies each card's crop at
//  composition time, so Photo 1 (portrait) and Photo 2 (hero) can use different shapes.
//

import UIKit

nonisolated enum PassportPhotoRole: Int, CaseIterable, Sendable {
    case portrait = 0
    case hero = 1

    nonisolated init?(photoIndex: Int) {
        self.init(rawValue: photoIndex)
    }

    nonisolated var title: String {
        switch self {
        case .portrait: "Portrait"
        case .hero: "Hero Photo"
        }
    }

    nonisolated var aspectRatio: CGSize {
        switch self {
        case .portrait: CGSize(width: 3, height: 4)
        case .hero: CGSize(width: 4, height: 3)
        }
    }

    nonisolated var thermalPresentationMode: ThermalPhotoPresentationMode {
        switch self {
        case .portrait: .portrait
        case .hero: .landscape
        }
    }

    /// Vertical crop anchor (0 = top, 0.5 = centre). Landscape crops from a portrait frame sit
    /// a little high so faces, which are usually in the upper half, stay in the shot.
    nonisolated var verticalAnchor: CGFloat {
        switch self {
        case .portrait: 0.5
        case .hero: 0.4
        }
    }
}

nonisolated enum PassportPhotoProcessor {
    nonisolated static let maximumSourceDimension: CGFloat = 2_400

    /// Orientation-normalized, uncropped source capped at a controlled size.
    nonisolated static func normalizedSource(from image: UIImage) -> UIImage {
        // UIImage.size already accounts for EXIF orientation, unlike the raw CGImage size.
        let pixelSize = CGSize(width: floor(image.size.width * image.scale), height: floor(image.size.height * image.scale))
        guard pixelSize.width > 0, pixelSize.height > 0 else { return image }
        let scale = min(1, maximumSourceDimension / max(pixelSize.width, pixelSize.height))
        let target = CGSize(width: max(1, floor(pixelSize.width * scale)), height: max(1, floor(pixelSize.height * scale)))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: target, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: target))
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }

    /// Crop for a legacy Passport card role (archived sessions). Delegates to the shared
    /// presentation geometry so capture, review and print use one crop formula.
    nonisolated static func presentationPhoto(from image: UIImage, role: PassportPhotoRole) -> UIImage {
        legacyGeometry(for: role).uprightPhoto(from: image)
    }

    /// Photo Pass prepares its sideways hero as an upright portrait before the renderer rotates it
    /// into the unchanged landscape opening. This is the exact crop the guest approved in review.
    nonisolated static func photoPassHeroPresentationPhoto(from image: UIImage) -> UIImage {
        PhotoPresentationGeometry.resolve(format: .passport, photoIndex: PassportPhotoRole.hero.rawValue, passportDesign: .photoPassV2)
            .uprightPhoto(from: image)
    }

    nonisolated static func cropRect(sourceSize: CGSize, role: PassportPhotoRole) -> CGRect {
        legacyGeometry(for: role).cropRect(sourceSize: sourceSize)
    }

    nonisolated private static func legacyGeometry(for role: PassportPhotoRole) -> PhotoPresentationGeometry {
        PhotoPresentationGeometry.resolve(format: .passport, photoIndex: role.rawValue, passportDesign: .legacyPassport)
    }

    /// Small, already-cropped image for on-screen review and previews (never full resolution).
    nonisolated static func screenPreview(from image: UIImage, role: PassportPhotoRole, maximumDimension: CGFloat = 720) -> UIImage {
        let cropped = presentationPhoto(from: image, role: role)
        let pixelSize = ThermalPhotoProcessor.pixelSize(of: cropped)
        let scale = min(1, maximumDimension / max(1, max(pixelSize.width, pixelSize.height)))
        guard scale < 1 else { return cropped }
        let target = CGSize(width: max(1, floor(pixelSize.width * scale)), height: max(1, floor(pixelSize.height * scale)))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            cropped.draw(in: CGRect(origin: .zero, size: target))
        }
    }
}
