//
//  PhotoPresentationGeometry.swift
//  PocketPixelsBooth
//
//  The single source of truth for how each captured photo is framed, shown and printed. The
//  live camera aperture, the capture confirmation, photo review, receipt composition and the
//  receipt preview all resolve this geometry, so the photo a guest approves is the photo that
//  prints.
//
//  Stored captures are never modified by presentation: `uprightPhoto(from:)` returns a crop of
//  the stored source, and the only print-time transform (the Photo Pass hero's quarter turn) is
//  described by `printRotation` and applied once, by the receipt renderer.
//

import UIKit

nonisolated struct PhotoPresentationGeometry: Equatable, Sendable {
    enum Orientation: Sendable, Equatable {
        case portrait
        case landscape
    }

    /// How the upright crop is placed into its printed opening.
    enum PrintRotation: Sendable, Equatable {
        /// Printed exactly as the guest sees it.
        case none
        /// Printed a quarter turn counterclockwise: the subject's head points to the receipt's
        /// left edge, so the guest turns the receipt clockwise to view it upright. Used by the
        /// Photo Pass upper card, which is designed to be read sideways.
        case counterclockwise90
    }

    /// Width:height of the upright crop the guest sees, approves and receives.
    let cropAspect: CGSize
    /// Where the crop sits when the source is taller than the crop (0 = top, 0.5 = centre).
    /// Horizontal placement is always centred.
    let verticalAnchor: CGFloat
    let printRotation: PrintRotation

    static let portrait = Self(cropAspect: CGSize(width: 3, height: 4), verticalAnchor: 0.5, printRotation: .none)
    static let landscape = Self(cropAspect: ReceiptComposer.landscapePresentationCropAspectRatio, verticalAnchor: 0.5, printRotation: .none)

    var aspectRatio: CGFloat {
        cropAspect.width / cropAspect.height
    }

    var orientation: Orientation {
        cropAspect.width > cropAspect.height ? .landscape : .portrait
    }

    var thermalPresentationMode: ThermalPhotoPresentationMode {
        orientation == .landscape ? .landscape : .portrait
    }

    /// Resolves the geometry for one photo slot. Photo Pass is the only format whose slots differ;
    /// archived legacy Passport sessions keep their original landscape hero for faithful reprints.
    static func resolve(
        format: BoothFormat,
        photoIndex: Int,
        passportDesign: PassportDesignVersion = .current
    ) -> Self {
        switch format {
        case .solo, .grid, .gridSix:
            return .portrait
        case .duo, .strip:
            return .landscape
        case .passport:
            switch PassportPhotoRole(photoIndex: photoIndex) {
            case .hero:
                switch passportDesign {
                case .photoPassV2:
                    // Upright 3:4 portrait, rotated once into the sideways upper card.
                    return Self(
                        cropAspect: CGSize(width: 3, height: 4),
                        verticalAnchor: PassportPhotoRole.hero.verticalAnchor,
                        printRotation: .counterclockwise90
                    )
                case .legacyPassport:
                    return Self(
                        cropAspect: PassportPhotoRole.hero.aspectRatio,
                        verticalAnchor: PassportPhotoRole.hero.verticalAnchor,
                        printRotation: .none
                    )
                }
            case .portrait, nil:
                return Self(
                    cropAspect: PassportPhotoRole.portrait.aspectRatio,
                    verticalAnchor: PassportPhotoRole.portrait.verticalAnchor,
                    printRotation: .none
                )
            }
        }
    }

    /// Integer pixel crop of an upright source. With a centre anchor this is identical to the
    /// thermal pipeline's centre crop, so composition never crops a second time.
    func cropRect(sourceSize: CGSize) -> CGRect {
        guard sourceSize.width > 0, sourceSize.height > 0, cropAspect.width > 0, cropAspect.height > 0 else {
            return .zero
        }
        let ratio = aspectRatio
        let size: CGSize
        if sourceSize.width / sourceSize.height > ratio {
            size = CGSize(width: floor(sourceSize.height * ratio), height: sourceSize.height)
        } else {
            size = CGSize(width: sourceSize.width, height: floor(sourceSize.width / ratio))
        }
        return CGRect(
            x: floor((sourceSize.width - size.width) / 2),
            y: floor((sourceSize.height - size.height) * verticalAnchor),
            width: size.width,
            height: size.height
        )
    }

    /// The upright photo exactly as the guest approves it. Crops with CGImage (no redraw) when
    /// the source is already upright; the stored source is never replaced.
    func uprightPhoto(from image: UIImage) -> UIImage {
        let upright = Self.uprightSource(image)
        guard let cgImage = upright.cgImage else { return upright }
        let rect = cropRect(sourceSize: CGSize(width: cgImage.width, height: cgImage.height))
        guard rect.width >= 1, rect.height >= 1, let cropped = cgImage.cropping(to: rect) else { return upright }
        return UIImage(cgImage: cropped, scale: 1, orientation: .up)
    }

    /// Pixel size the upright photo is prepared at for a printed opening of `openingSize`.
    /// A rotated photo is prepared at the opening's transposed size and turned by the renderer.
    func preparedPixelSize(forOpening openingSize: CGSize) -> CGSize {
        switch printRotation {
        case .none:
            openingSize
        case .counterclockwise90:
            CGSize(width: openingSize.height, height: openingSize.width)
        }
    }

    /// Shape of the printed opening for a given upright crop, in receipt coordinates.
    var printedOpeningAspectRatio: CGFloat {
        printRotation == .counterclockwise90 ? 1 / aspectRatio : aspectRatio
    }

    private static func uprightSource(_ image: UIImage) -> UIImage {
        if image.imageOrientation == .up, image.cgImage != nil {
            return image
        }
        // UIImage.size already reflects EXIF orientation; drawing bakes it into the pixels.
        let pixelSize = CGSize(width: floor(image.size.width * image.scale), height: floor(image.size.height * image.scale))
        guard pixelSize.width > 0, pixelSize.height > 0 else { return image }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: pixelSize, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: pixelSize))
            image.draw(in: CGRect(origin: .zero, size: pixelSize))
        }
    }
}
